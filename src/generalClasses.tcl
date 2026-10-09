namespace eval spicetracesurfer {}

oo::configurable create ::spicetracesurfer::DataSource {
    # This class models general source of data - raw file, csv file, result of calculation, network or spreadsheet.
    # Class abstracts operations of data acquisition from different sources and produce Dataset.
    property name -set {
        if {$value eq {}} {
            return -code error {Name cannot be empty string}
        } else {
            set name $value
        }
    }
    property type -set {
        classvariable SourceTypes
        if {$value ni $SourceTypes} {
            return -code error "Source type '$value' is not one of the allowed types: [join $SourceTypes {, }]"
        } else {
            set type $value
        }
    }
    property filetype -set {
        classvariable FileTypes
        if {$type ne {file}} {
            return -code error "To set filetype type must be file, but type is '[my configure -type]'"
        } else {
            if {$value ni $FileTypes} {
                return -code error "File type '$value' is not one of the allowed types: [join $FileTypes {, }]"
            } else {
                set filetype $value
            }
        }
    }
    property filepath -set {
        if {$type ne {file}} {
            return -code error "To set filepath type must be file, but type is '[my configure -type]'"
        } else {
            set filepath $value
        }
    }
    property dialect
    property csvbatchsize -set {
        if {![string is integer -strict $value] || $value <= 0} {
            return -code error {CSV batch size must be a positive integer}
        }
        set csvbatchsize $value
    }
    property csvdelimiter -set {
        if {[string length $value] != 1 || ![string is ascii -strict $value]} {
            return -code error {CSV delimiter must be a single ASCII character}
        }
        set csvdelimiter $value
    }
    property csvencoding -set {
        # Asking Tcl to convert an empty string validates the encoding name
        # without opening a file, and supports lazily loaded encodings.
        if {[catch {encoding convertfrom $value {}} message]} {
            return -code error "Invalid CSV encoding '$value': $message"
        }
        set csvencoding $value
    }
    property csvheader -set {
        if {![string is boolean -strict $value]} {
            return -code error {CSV header flag must be a boolean}
        }
        set csvheader $value
    }
    property csvnametemplate -set {
        if {[catch {
            set firstName [format $value 1]
            set secondName [format $value 2]
        } message]} {
            return -code error "Invalid CSV name template: $message"
        }
        if {([string trim $firstName] eq {}) || ([string trim $secondName] eq {})} {
            return -code error {CSV name template must produce nonempty column names}
        }
        if {$firstName eq $secondName} {
            return -code error {CSV name template must produce distinct column names}
        }
        set csvnametemplate $value
    }
    variable name type filepath filetype dialect FileHandle RawPlots Traces
    variable csvbatchsize csvdelimiter csvencoding csvheader csvnametemplate
    initialize {
        variable SourceTypes
        const SourceTypes {file calculation network spreadsheet}
        variable FileTypes
        const FileTypes {raw csv touchstone}
    }
    constructor {args} {
        set arguments [argparse -inline -pfirst {
            name 
            {type -optional -default file}
            -filepath=
            -filetype=
            {-dialect= -default generic}
            {-csvbatchsize= -default 8192}
            {-csvdelimiter= -default ,}
            {-csvencoding= -default utf-8}
            {-csvheader= -default true}
            {-csvnametemplate= -default column%d}
        }]
        set Traces [dict create]
        set RawPlots [dict create]
        my configure -name [dict get $arguments name]
        my configure -type [dict get $arguments type]
        foreach option {csvbatchsize csvdelimiter csvencoding csvheader csvnametemplate} {
            my configure -$option [dict get $arguments $option]
        }
        if {[dict get $arguments type] eq {file}} {
            my configure -filepath [dict get $arguments filepath]
            my configure -filetype [dict get $arguments filetype]
        }
        if {($type eq {file}) && ($filetype eq {raw})} {
            my configure -dialect [dict get $arguments dialect]
            my CreateAndFillRaw
        } elseif {($type eq {file}) && ($filetype eq {csv})} {
            my CreateAndFillCsv
        }
    }
    destructor {
        if {[info exists Traces]} {
            if {$Traces ne {}} {
                dict for {name trace} $Traces {
                    $trace destroy
                }
            }
        }
        if {[info exists RawPlots]} {
            if {$RawPlots ne {}} {
                dict for {name rawPlot} $RawPlots {
                    $rawPlot destroy
                }
            }
        }
        if {[info exists FileHandle]} {
            $FileHandle close
        }
    }
    method CreateAndFillRaw {} {
        set FileHandle [tclsimrawreader::openraw -dialect $dialect -output vector -ifexists error $filepath]
        set rawPlotsInfo [$FileHandle plots]
        foreach rawPlotInfo $rawPlotsInfo {
            set rawPlotIndex [dict get $rawPlotInfo index]
            set rawPlotHeaderInfo [$FileHandle header -plot $rawPlotIndex]
            set rawPlotVariablesInfo [dict get $rawPlotHeaderInfo variables]
            set rawPlotName "plot$rawPlotIndex"
            set rawPlotObj [::spicetracesurfer::RawPlot new $rawPlotName $rawPlotIndex [self]]
            dict set RawPlots $rawPlotName $rawPlotObj
            foreach rawPlotVaribleInfo $rawPlotVariablesInfo {
                set rawVariableName [dict get $rawPlotVaribleInfo name]
                set traceObj [::spicetracesurfer::Trace new $rawVariableName [dict get $rawPlotVaribleInfo type] [self]]
                $rawPlotObj addTrace $traceObj
            }
        }
    }
    method CreateAndFillCsv {} {
        # Eagerly read a numeric CSV with an optional header. Only one batch of
        # row/column lists is retained; completed data lives in real RBC vectors.
        # CSV has no physical-unit metadata, so Trace.type is initially unknown.
        if {[dict size $Traces] != 0} {
            return -code error {CSV loading requires an empty trace collection}
        }
        set channel [open $filepath r]
        set reader {}
        set vectors {}
        set pendingTraces {}
        try {
            chan configure $channel -encoding $csvencoding -translation auto
            set reader [tclcsv::reader new -delimiter $csvdelimiter $channel]
            # Keep this reader alive: it may buffer data beyond the first row.
            set firstRows [$reader next 1]
            if {[llength $firstRows]==0} {
                return -code error {CSV file has no records}
            }
            set firstRow [lindex $firstRows 0]
            # Accept the common UTF-8 BOM, but preserve names otherwise.
            lset firstRow 0 [string trimleft [lindex $firstRow 0] \ufeff]
            set columnCount [llength $firstRow]
            if {$csvheader} {
                set headers $firstRow
                set rows {}
                set recordNumber 1
            } else {
                set headers {}
                for {set i 1} {$i<=$columnCount} {incr i} {
                    # Tcl format template with a one-based column number.
                    lappend headers [format $csvnametemplate $i]
                }
                set rows [list $firstRow]
                set recordNumber 0
            }
            set seen {}
            foreach header $headers {
                if {[string trim $header] eq {}} {
                    return -code error {CSV column names must not be empty}
                }
                if {[dict exists $seen $header]} {
                    return -code error "Duplicate CSV column name '$header'"
                }
                dict set seen $header 1
            }
            for {set i 0} {$i<$columnCount} {incr i} {
                # Generated internal names avoid treating header punctuation
                # (e.g. v(2), spaces or ::) as vector-name syntax.
                set vecName [info object namespace [self]]::csvColumn$i
                if {[namespace which -command $vecName] ne {}} {
                    return -code error "CSV vector command '$vecName' already exists"
                }
                lappend vectors [rbc::vector create $vecName -variable {}]
            }
            while {1} {
                # The first headerless row is already buffered as data.
                if {[llength $rows]==0} {
                    set rows [$reader next $csvbatchsize]
                }
                if {[llength $rows]==0} {
                    break
                }
                for {set i 0} {$i < $columnCount} {incr i} {
                    set columns($i) {}
                }
                foreach row $rows {
                    incr recordNumber
                    if {[llength $row] != $columnCount} {
                        return -code error "CSV record $recordNumber has [llength $row] fields; expected $columnCount"
                    }
                    set i 0
                    foreach value $row {
                        set value [string trim $value]
                        if {![string is double -strict $value]} {
                            return -code error "CSV record $recordNumber, column '[lindex $headers $i]':\
                                    expected a number, got '$value'"
                        }
                        lappend columns($i) $value
                        incr i
                    }
                }
                # One vector append per column per batch, not per sample.
                set i 0
                foreach vec $vectors {
                    $vec append $columns($i)
                    incr i
                }
                unset columns
                set rows {}
            }
            # Assign fully populated vectors before publishing any traces.
            foreach header $headers vec $vectors {
                set trace [::spicetracesurfer::Trace new -vector $vec -- $header unknown [self]]
                lappend pendingTraces $trace
            }
            # Close input before committing ownership to the source.
            $reader destroy
            set reader {}
            close $channel
            set channel {}
            foreach trace $pendingTraces {
                my addTrace $trace
            }
        } on error {message options} {
            # A failed constructor must not leave vectors or Trace objects.
            foreach trace $pendingTraces {
                catch {$trace destroy}
            }
            foreach vec $vectors {
                if {[namespace which -command $vec] ne {}} {
                    catch {rbc::vector destroy $vec}
                }
            }
            set Traces {}
            return -options $options $message
        } finally {
            if {$reader ne {}} {
                catch {$reader destroy}
            }
            if {$channel ne {}} {
                catch {close $channel}
            }
        }
    }
    method readRawVector {plot name namespace} {
        if {$type eq {file}} {
            if {$filetype eq {raw}} {
                return [$FileHandle vector -plot $plot $name -name ${namespace}::$name]
            } else {
                return -code error "Raw vector cannot be readed because file type of data source is not raw"
            }
        } else {
            return -code error "Raw vector cannot be readed because data source is not a file type"
        }
    }
    method getRawPlot {name} {
        return [dict get $RawPlots $name]
    }
    method getRawPlots {} {
        return $RawPlots
    }
    method addTrace {trace} {
        dict set Traces [$trace configure -name] $trace
        $trace configure -rawplot {}
    }
    method getTrace {name} {
        return [dict get $Traces $name]
    }
    method getTraces {} {
        return $Traces
    }
}

oo::configurable create ::spicetracesurfer::RawPlot {
    property name
    property index
    property source -set {
        if {![info object class $value ::spicetracesurfer::DataSource]} {
            return -code error "Source must be an object of class ::spicetracesurfer::DataSource"
        } else {
            set source $value
        }
    }
    property fullname -kind readable -get {
        return "[$source configure -name].$name"
    }
    variable name fullname source Traces
    constructor {args} {
        set arguments [argparse -inline {
            name
            index
            source
        }]
        dict for {elName elValue} $arguments {
            my configure -$elName $elValue
        }
        set Traces [dict create]
    }
    destructor {
        if {[info exists Traces]} {
            if {$Traces ne {}} {
                dict for {name trace} $Traces {
                    $trace destroy
                }
            }
        }
    }
    method addTrace {trace} {
        dict set Traces [$trace configure -name] $trace
        $trace configure -rawplot [self]
    }
    method getTrace {name} {
        return [dict get $Traces $name]
    }
    method getTraces {} {
        return $Traces
    }
}

oo::configurable create ::spicetracesurfer::Trace {
    property name
    property fullname -kind readable -get {
        if {[info exists rawplot] && $rawplot ne {}} {
            return "[$rawplot configure -fullname].$name"
        }
        return "[$source configure -name].$name"
    }
    property type
    property numtype -get {
        if {[info exists vector]} {
            return [$vector type]
        } else {
            return $numtype
        }
    } -set {
        if {[info exists vector]} {
            set numtype [$vector type]
        } else {
            set numtype $value
        }
    }
    property vector
    property length -get {
        if {[info exists vector]} {
            return [$vector length]
        } else {
            return $length
        }
    } -set {
        if {[info exists vector]} {
            set length [$vector length]
        } else {
            set length $value
        }
    }
    property source -set {
        if {![info object class $value ::spicetracesurfer::DataSource]} {
            return -code error "Source must be an object of class ::spicetracesurfer::DataSource"
        } else {
            set source $value
        }
    }
    property rawplot
    property axis
    variable name fullname type numtype length vector source rawplot axis
    constructor {args} {
        set arguments [argparse -inline  {
            name
            type
            source
            -vector=
        }]
        dict for {elName elValue} $arguments {
            my configure -$elName $elValue
        }
    }
    destructor {
        if {[info exists vector]} {
            if {$vector ne {}} {
                rbc::vector destroy $vector
            }
        }
    }
    method getVector {} {
        if {[info exists vector]} {
            return [my configure -vector]
        } else {
            my configure -vector [[my configure -source] readRawVector [[my configure -rawplot] configure -index]\
                                          [my configure -name] [self]]
            return $vector
        }
    }
}
