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

# Session evaluator. Sources are borrowed; result traces belong to ResultSource.
oo::configurable create ::spicetracesurfer::Evaluator {
    property resultsource -kind readable -get {
        return $ResultSource
    }
    property resultalias -kind readable -get {
        return $ResultAlias
    }
    variable Sources ResultSource ResultAlias ScriptNamespace Serial

    constructor {args} {
        set arguments [argparse -inline {
            -resultsource=
            {-resultalias= -default results}
        }]
        set Sources {}
        set Serial 0
        set ResultSource [dict get $arguments resultsource]
        set ResultAlias [dict get $arguments resultalias]
        my CheckResultSource
        my attach $ResultSource -name $ResultAlias
        set ScriptNamespace [info object namespace [self]]::script
        namespace eval $ScriptNamespace {}
        foreach command {trace derive publish} {
            interp alias {} ${ScriptNamespace}::$command {} [self] $command
        }
    }

    # The object namespace (including script commands/variables) is removed by
    # TclOO. Borrowed sources and their result vectors deliberately survive.
    method CheckSource {source} {
        if {![info object isa typeof $source ::spicetracesurfer::DataSource]} {
            return -code error {Source must be a live spicetracesurfer::DataSource object}
        }
    }
    method CheckResultSource {} {
        my CheckSource $ResultSource
        if {[$ResultSource configure -type] ne {calculation}} {
            return -code error {Result source must have type calculation}
        }
    }
    method attach {args} {
        set arguments [argparse -inline -pfirst {
            source
            -name=
        }]
        my CheckSource [dict get $arguments source]
        set alias [[dict get $arguments source] configure -name]
        if {[dict exists $arguments name]} {
             set alias [dict get $arguments name]
        }
        if {$alias eq {}} {
            return -code error {Source alias must not be empty}
        }
        if {[dict exists $Sources $alias]} {
            return -code error "Source alias '$alias' is already attached"
        }
        dict set Sources $alias [dict get $arguments source]
        return $alias
    }
    method detach {alias} {
        if {$alias eq $ResultAlias} {
            return -code error {Cannot detach the result source alias}
        }
        if {![dict exists $Sources $alias]} {
            return -code error "Source alias '$alias' is not attached"
        }
        dict unset Sources $alias
    }
    method getSources {} {
        return $Sources
    }
    method evaluate {script} {
        namespace eval $ScriptNamespace $script
    }
    method trace {args} {
        set arguments [argparse -inline {
            alias
            {plotname -optional}
            tracename
        }]
        if {![dict exists $Sources [dict get $arguments alias]]} {
            return -code error "Source alias '[dict get $arguments alias]' is not attached"
        }
        set source [dict get $Sources [dict get $arguments alias]]
        my CheckSource $source
        if {![dict exists $arguments plotname]} {
            set object [$source getTrace [dict get $arguments tracename]]
        } else {
            set object [[$source getRawPlot [dict get $arguments plotname]] getTrace [dict get $arguments tracename]]
        }
        return [$object getVector]
    }
    method CheckResultName {name} {
        my CheckResultSource
        if {$name eq {}} {
            return -code error {Result trace name must not be empty}
        }
        if {[dict exists [$ResultSource getTraces] $name]} {
            return -code error "Result trace '$name' already exists"
        }
    }
    method NewVectorName {} {
        my CheckResultSource
        set prefix [info object namespace $ResultSource]::eval[info object creationid [self]]_
        while {1} {
            set name $prefix[incr Serial]
            if {([namespace which -command $name] eq {}) && ($name ni [rbc::vector names])} {
                return $name
            }
        }
    }
    method derive {args} {
        # Let RBC create a destination with the expression's actual numeric
        # type. Explicit real/complex modes retain the previous behaviour.
        set arguments [argparse -inline -pfirst {
            name
            expression
            {-type= -default unknown}
            {-numtype= -default auto}
        }]
        my CheckResultName [dict get $arguments name]
        set numtype [dict get $arguments numtype]
        if {$numtype ni {auto real complex}} {
            return -code error {Numeric type must be auto, real or complex}
        }
        set vector {}
        set committed 0
        try {
            if {$numtype eq {auto}} {
                set vector [namespace eval $ScriptNamespace [list ::rbc::vector expr -name [my NewVectorName]\
                                                                     [dict get $arguments expression]]]
            } else {
                set vector [rbc::vector create [my NewVectorName] -type $numtype -variable {}]
                namespace eval $ScriptNamespace [list $vector expr [dict get $arguments expression]]
            }
            set object [my publish [dict get $arguments name] $vector -type [dict get $arguments type]]
            set committed 1
            return $object
        } finally {
            if {!$committed && ($vector ne {}) && ($vector in [rbc::vector names])} {
                rbc::vector destroy $vector
            }
        }
    }
    method VectorOwner {vector} {
        # Include subclasses; inspect only already assigned vectors so checking
        # ownership never triggers lazy loading from an unrelated data source.
        set classes [list ::spicetracesurfer::Trace]
        set visited {}
        while {[llength $classes]} {
            set class [lindex $classes 0]
            set classes [lrange $classes 1 end]
            if {$class in $visited} {continue}
            lappend visited $class
            lappend classes {*}[info class subclasses $class]
            foreach object [info class instances $class] {
                set ns [info object namespace $object]
                if {[info exists ${ns}::vector] && ([set ${ns}::vector] eq $vector)} {
                    return $object
                }
            }
        }
        return
    }
    method publish {args} {
        set arguments [argparse -inline -pfirst {
            name
            vector
            {-type= -default unknown}
        }]
        my CheckResultName [dict get $arguments name]
        # Relative vector commands are resolved in the user session, even when
        # publish is invoked directly as an evaluator method.
        set vector [namespace eval $ScriptNamespace [list namespace which -command [dict get $arguments vector]]]
        if {($vector eq {}) || ($vector ni [rbc::vector names])} {
            return -code error {Publish requires an existing RBC vector with its standard command name}
        }
        set owner [my VectorOwner $vector]
        if {$owner ne {}} {
            return -code error "Vector is already owned by trace '$owner'"
        }
        set object [::spicetracesurfer::Trace new -- [dict get $arguments name] [dict get $arguments type]\
                            $ResultSource]
        set original $vector
        set mapping [$vector variable]
        set moved 0
        set committed 0
        try {
            # Move the vector command out of the evaluator namespace so it
            # survives evaluator destruction. RBC rename does not copy samples.
            set vector [rbc::vector rename $vector [my NewVectorName]]
            set moved 1
            # A mapped array may live in the script namespace and have
            # -watchunset enabled. Remove that association on ownership transfer.
            $vector variable {}
            $object configure -vector $vector
            $ResultSource addTrace $object
            set committed 1
            return $object
        } finally {
            if {!$committed} {
                # Keep caller ownership on failure after a successful move.
                if {$moved && ($vector in [rbc::vector names])} {
                    catch {rbc::vector rename $vector $original}
                    if {$mapping ne {}} {
                        catch {$original variable $mapping}
                    }
                }
                if {[info object isa object $object]} {
                    $object configure -vector {}
                    $object destroy
                }
            }
        }
    }
}
