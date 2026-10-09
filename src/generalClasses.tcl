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
    variable name type filepath filetype dialect FileHandle RawPlots Traces
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
        }]
        set Traces [dict create]
        set RawPlots [dict create]
        my configure -name [dict get $arguments name]
        my configure -type [dict get $arguments type]
        if {[dict get $arguments type] eq {file}} {
            my configure -filepath [dict get $arguments filepath]
            my configure -filetype [dict get $arguments filetype]
        }
        if {($type eq {file}) && ($filetype eq {raw})} {
            my configure -dialect [dict get $arguments dialect]
            my CreateAndFillRaw
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
        if {$type eq {file}} {
            if {$filetype eq {raw}} {
                $FileHandle close
            }
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
            set rawPlotObj [::spicetracesurfer::RawPlot new  $rawPlotName $rawPlotIndex [self]]
            dict set RawPlots $rawPlotName $rawPlotObj
            foreach rawPlotVaribleInfo $rawPlotVariablesInfo {
                set rawVariableName [dict get $rawPlotVaribleInfo name]
                set traceObj [::spicetracesurfer::Trace new $rawVariableName [dict get $rawPlotVaribleInfo type] [self]]
                $rawPlotObj addTrace $traceObj
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
        return "[[my configure -rawplot] configure -fullname].$name"
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
