namespace eval spicetracesurfer {}

oo::configurable create ::spicetracesurfer::DataSource {
    classmethod _ruffClassHook {} {
        # Supplies class and property documentation to Ruff.
        #
        # Returns: Ruff class metadata dictionary.
        return {
            preamble {
                A named owner of waveform data, raw plots and traces.

                RAW files create plot/trace metadata at construction and load individual RBC vectors on demand. CSV
                files populate all vectors immediately in bounded batches and attach traces directly to the
                source. Calculation sources hold results published by an Evaluator. Other source/file types are
                accepted as metadata but do not yet have acquisition implementations.

                Use inherited `configure -property` to read a property and `configure -property value` to set it.
                Construction and reconfiguration share the property setters. Invalid values leave that property's old
                value intact; a multi-property configure call is not transactional. Changing file or CSV settings does
                not reload existing data, change existing trace names, or rebuild indexes.

                ## CSV input
                CSV input defaults to UTF-8, comma-separated fields and a header in the first nonblank record. Header
                presence is explicit, not guessed. With `-csvheader false`, the first record determines the column
                count and remains data. `-csvnametemplate` is a Tcl format template receiving a one-based column
                number; the default yields column1, column2, and so on.

                ```tcl
                set source [::spicetracesurfer::DataSource new measurements file -filepath measurements.csv\
                                    -filetype csv -csvheader false -csvnametemplate {signal_%03d} -csvdelimiter {;}\
                                    -csvbatchsize 4096]
                set trace [$source getTrace signal_002]
                set vector [$trace getVector]
                puts [$trace configure -fullname]
                ```

                Column names must be nonempty and unique. Header names retain punctuation and spaces; internal vector
                names are generated independently. Each data record must have the same field count.  Cells must be real
                numbers recognized by Tcl, with surrounding whitespace ignored. Empty cells, text and SPICE suffixes
                such as 10k are rejected. tclcsv handles quoting and skips blank lines. Diagnostics count logical CSV
                records, which can span physical lines. Header-only input creates empty vectors; input with no records
                is an error. CSV trace physical types start as unknown; units and axis assignments are not inferred.

                The loader reads rows in batches, transposes each batch and appends one list per column. Temporary list
                storage is bounded by the batch size; all completed vectors remain resident. Loading is synchronous and
                does not yield to the Tk event loop. The file channel and parser are closed after loading. No RawPlot
                objects are created for CSV sources.

                ## Ownership
                A source owns its directly registered traces and raw plots; each plot owns its traces, and each
                trace owns its vector. Destroying the source destroys this owned data and closes a RAW reader.
                Keep registered names stable: changing a child's name property does not rekey its owner's dictionary.
                The low-level addTrace method replaces dictionary entries without destroying the previous object;
                callers must prevent duplicates and avoid assigning the same vector to multiple owning traces.
            }
            propertydescriptions {
                -name {
                    Nonempty display name. Application-level uniqueness is the caller's responsibility.
                }
                -type {
                    Source category: file, calculation, network or spreadsheet. Defaults to file.
                }
                -filetype {
                    File format: raw, csv or touchstone. Can be assigned only when type is file. RAW and CSV
                    acquisition are implemented.
                }
                -filepath {
                    File path. Can be assigned only when type is file; construction opens it for RAW or CSV input.
                }
                -dialect {
                    RAW reader dialect. Defaults to generic for RAW construction and is passed to tclsimrawreader.
                }
                -csvbatchsize {
                    Positive integer batch size; default 8192 records. Validated before assignment.
                }
                -csvdelimiter {
                    A single ASCII delimiter character; default comma. Passed to tclcsv.
                }
                -csvencoding {
                    Valid Tcl channel encoding; default utf-8. The setter validates the name through encoding
                    convertfrom.
                }
                -csvheader {
                    Tcl boolean indicating a header record; default true. Changing it does not reload the source.
                }
                -csvnametemplate {
                    Tcl format template for headerless column names; default column%d. Receives a one-based index. The
                    setter checks nonempty, distinct names for indices 1 and 2; loading checks uniqueness for every
                    actual column.
                }
            }
        }
    }
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
        # Constructs a source and acquires its initial data or metadata.
        # name - Nonempty source display name.
        # type - Source category: file (default), calculation, network or spreadsheet.
        # -filepath - path: File path; required for a file source.
        # -filetype - format: File format: raw, csv or touchstone; required for a file source.
        # -dialect - dialect: RAW reader dialect; defaults to generic.
        # -csvbatchsize - count: Positive number of records per batch; defaults to 8192.
        # -csvdelimiter - char: Single ASCII field separator; defaults to comma.
        # -csvencoding - encoding: Tcl input encoding; defaults to utf-8.
        # -csvheader - boolean: Whether the first nonblank record contains names; defaults to true.
        # -csvnametemplate - template: Headerless column-name format receiving a one-based index; defaults to column%d.
        #
        # The name is required and the source type defaults to file. File sources require filepath and
        # filetype. RAW input builds plot metadata; CSV input eagerly loads numeric vectors.
        # CSV settings are configured through their property setters before acquisition.
        #
        # Synopsis: name ?type? ?-filepath path? ?-filetype format? ?-dialect dialect? ?-csvbatchsize count?
        # ?-csvdelimiter char? ?-csvencoding encoding? ?-csvheader boolean? ?-csvnametemplate template?
        # Returns: The new DataSource object command.
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
        # Destroys owned traces and raw plots, then closes an existing RAW reader.
        #
        # Registered objects and vectors must not be shared between owners.
        # Returns: Nothing.
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
        # Creates the RAW reader and populates plot and trace metadata.
        #
        # Internal method. Uses filepath and dialect with vector output and collision errors enabled.  Stores the reader
        # for subsequent lazy vector reads; does not read trace samples here.
        # Returns: No public result.
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
        # Loads numeric CSV records in batches and publishes directly owned traces.
        #
        # Internal method. Reads the validated CSV properties, requires an empty trace collection, and keeps one tclcsv
        # reader alive across the header and data so buffered input is preserved.  Validates names, row widths and
        # numeric cells, transposes each batch and appends per column.  Populated vectors are assigned to traces only
        # after reading completes. The finally block closes parser/channel resources; the error handler cleans up
        # tracked partial results.
        # Returns: No public result.
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
        # Reads one RAW variable into a named RBC vector.
        # plot - RAW plot index.
        # name - RAW variable name.
        # namespace - Namespace prefix for the destination vector name.
        #
        # Requires a file source whose filetype is raw. The reader constructs namespace::name and uses its configured
        # collision policy. Called by Trace.getVector for lazy loading.
        # Returns: The RBC vector name returned by the RAW reader.
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
        # Looks up a registered RAW plot.
        # name - Local plot name, such as plot0.
        #
        # An unknown name raises a dictionary lookup error.
        # Returns: The RawPlot object command.
        return [dict get $RawPlots $name]
    }
    method getRawPlots {} {
        # Returns the registered RAW plot dictionary.
        #
        # CSV and calculation sources normally have an empty dictionary.
        # Returns: Dictionary mapping local plot names to RawPlot objects.
        return $RawPlots
    }
    method addTrace {trace} {
        # Registers a trace directly under this source and clears its rawplot property.
        # trace - Trace object to register, indexed by its current name.
        #
        # The caller must supply a trace with the correct source and unique ownership. Existing
        # entries with the same name are replaced without destroying their former trace object.
        # Returns: No public result.
        dict set Traces [$trace configure -name] $trace
        $trace configure -rawplot {}
    }
    method getTrace {name} {
        # Looks up a directly owned trace.
        # name - Local trace name.
        #
        # Does not search RAW plots. An unknown name raises a dictionary lookup error.
        # Returns: The Trace object command.
        return [dict get $Traces $name]
    }
    method getTraces {} {
        # Returns directly registered traces without loading vectors.
        #
        # Returns: Dictionary mapping local trace names to Trace objects.
        return $Traces
    }
}

oo::configurable create ::spicetracesurfer::RawPlot {
    classmethod _ruffClassHook {} {
        # Supplies class and property documentation to Ruff.
        #
        # Returns: Ruff class metadata dictionary.
        return {
            preamble {
                Metadata and trace ownership for one plot within a RAW data source.

                The source constructs plots while enumerating RAW headers. Plot construction alone does not read sample
                vectors. A plot's fullname combines its source name and local plot name for display; it is not an
                unambiguous serialization of unrestricted hierarchical names.

                Destroying the plot destroys its registered traces. The source owns registered plots; do not destroy
                one independently while leaving it registered. Keep registered trace names stable, and prevent multiple
                owners for a trace or vector.
            }
            propertydescriptions {
                -name {
                    Local plot name, normally plot followed by the RAW plot index. No automatic registry rekeying on
                    change.
                }
                -index {
                    Plot index passed to the RAW reader when fetching a vector.
                }
                -source {
                    Owning DataSource object, validated by the setter. Supplied at construction.
                }
                -fullname {
                    Read-only display name sourceName.plotName, computed from current names.
                }
            }
        }
    }
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
        # Constructs metadata for a RAW plot with an empty trace collection.
        # name - Local plot name, normally plot followed by its index.
        # index - RAW reader plot index.
        # source - Owning DataSource object.
        #
        # Synopsis: name index source
        # Returns: The new RawPlot object command.
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
        # Destroys every registered trace and its owned vector.
        #
        # Returns: Nothing.
        if {[info exists Traces]} {
            if {$Traces ne {}} {
                dict for {name trace} $Traces {
                    $trace destroy
                }
            }
        }
    }
    method addTrace {trace} {
        # Registers a trace and assigns this plot as its rawplot.
        # trace - Trace object indexed by its current name.
        #
        # The caller is responsible for source consistency and unique ownership. Duplicate names replace dictionary
        # entries without destroying the previous trace.
        # Returns: No public result.
        dict set Traces [$trace configure -name] $trace
        $trace configure -rawplot [self]
    }
    method getTrace {name} {
        # Looks up a trace within this plot.
        # name - Local trace name; unknown names raise a dictionary lookup error.
        #
        # Returns: The Trace object command.
        return [dict get $Traces $name]
    }
    method getTraces {} {
        # Returns trace metadata without loading vectors.
        #
        # Returns: Dictionary mapping local trace names to Trace objects.
        return $Traces
    }
}

oo::configurable create ::spicetracesurfer::Trace {
    classmethod _ruffClassHook {} {
        # Supplies class and property documentation to Ruff.
        #
        # Returns: Ruff class metadata dictionary.
        return {
            preamble {
                A named waveform descriptor owning an optional RBC vector.

                RAW traces are initially metadata-only. Calling getVector reads and caches the vector through the
                source and plot. CSV and derived traces receive populated vectors immediately. Physical type (for
                example voltage or time) is separate from numeric type (real or complex).

                A source-owned trace has no raw plot and displays sourceName.traceName. A RAW trace displays
                sourceName.plotName.traceName. Names may contain dots and are display labels; evaluator lookup uses
                separate source, plot and trace arguments instead of splitting a fullname.

                The trace destroys its assigned nonempty vector on destruction. Vector ownership must be unique. The
                vector property is a low-level assignment: replacing it does not destroy the former vector. An unset
                vector means not loaded; assigning an empty vector name is intended for ownership cleanup, not for
                subsequent length, numtype or getVector queries. Unloaded length and numeric-type metadata must be
                assigned before being queried. Axis is application metadata and is not set automatically.
            }
            propertydescriptions {
                -name {
                    Local trace name; changing it does not rekey the owning source or plot dictionary.
                }
                -fullname {
                    Read-only display name computed from the source and optional raw plot.
                }
                -type {
                    Physical data type or unit category; CSV and derived traces default to unknown.
                }
                -numtype {
                    Numeric type. When a vector exists, getter and setter use its actual type; assignment does not
                    convert the vector. Otherwise stores supplied metadata.
                }
                -vector {
                    Owned RBC vector command name. Optional at construction; getVector loads RAW data when unset.
                }
                -length {
                    Sample count. When a vector exists, getter and setter use its actual length; assignment does not
                    resize it. Otherwise stores supplied metadata.
                }
                -source {
                    Owning DataSource object, validated by the setter.
                }
                -rawplot {
                    RawPlot object for RAW traces, or empty for directly source-owned traces; set by the owner's
                    addTrace method.
                }
                -axis {
                    Application-defined axis association. No default, validation or automatic axis inference.
                }
            }
        }
    }
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
        # Constructs a waveform descriptor, optionally taking ownership of an existing vector.
        # name - Local trace name.
        # type - Physical data type, for example voltage or time.
        # source - Owning DataSource object.
        # -vector - vectorName: Optional existing RBC vector whose ownership is assigned to the trace.
        #
        # The constructor validates the source through its setter. Registration with a source or plot is a separate
        # operation performed by that owner's addTrace method.
        # Synopsis: name type source ?-vector vectorName?
        # Returns: The new Trace object command.
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
        # Destroys the assigned vector when its property exists and is nonempty.
        #
        # Returns: Nothing.
        if {[info exists vector]} {
            if {$vector ne {}} {
                rbc::vector destroy $vector
            }
        }
    }
    method getVector {} {
        # Returns the assigned vector, lazily loading RAW samples when it is unset.
        #
        # Lazy loading requires a source and rawplot with a valid reader index. The resulting vector name is cached in
        # the vector property. CSV and calculated traces return their already assigned vector directly; this method does
        # not copy its data.
        # Returns: The RBC vector command name.
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
    classmethod _ruffClassHook {} {
        # Supplies class and property documentation to Ruff.
        #
        # Returns: Ruff class metadata dictionary.
        return {
            preamble {
                Persistent calculation session with explicitly attached, borrowed DataSource objects.

                The supplied result source must have type calculation. It is automatically attached as results, or the
                alias specified by -resultalias. Aliases are literal strings, remain stable when source display names
                change, and must be nonempty and unique. The trace resolver consults only attached sources. Separate
                arguments permit filenames and trace names containing dots, spaces and parentheses.

                ```tcl
                set calculations [::spicetracesurfer::DataSource new derived calculation]
                set evaluator [::spicetracesurfer::Evaluator new -resultsource $calculations]
                $evaluator attach $rawSource -name simulation
                $evaluator evaluate {
                    set scale 1000
                    derive output_mV {
                        $scale * [trace simulation plot0 {v(out)}]
                    } -type voltage
                    derive magnitude {abs([trace results output_mV])}
                }
                set resultVector [[$calculations getTrace magnitude] getVector]
                ```

                ## Execution environment
                User variables and helper procedures persist in a child namespace of the evaluator object namespace.
                The commands trace, derive and publish are aliases to evaluator methods. RBC substitutions execute
                in the script namespace, allowing session variables, helper procedures and trace lookups in expressions.
                Separate evaluator objects have separate script namespaces. This is organisation for trusted scripts,
                not a security sandbox: fully qualified Tcl commands can access other application state.

                ## Results and ownership
                The calculation source owns published traces and vectors. The evaluator borrows sources and never
                destroys them. Destroying the evaluator removes its script namespace, aliases and user procedures;
                published results survive. Destroying the calculation source destroys its traces and their vectors.
                Lookups validate source liveness; external renaming of source object commands is not tracked.

                Automatic numeric typing requires RBC's named expression result API, added in rbc-tk9 commit 8c1713e.
                The evaluator evaluates each expression once without converting its result through a Tcl list.
                Complex inputs can produce real results, such as abs of a complex vector. Explicit real and complex
                modes remain available. The physical -type option is independent of numeric type.

                Only derive and publish create registered result traces; arbitrary temporary user vectors do not
                become traces automatically. Publication moves the vector command into the calculation source's
                namespace without copying samples, and removes any mapped array association. The old command name
                becomes invalid; retrieve the new command through the returned trace's getVector method.

                Result names must be nonempty and unique. Failed evaluation does not register its result trace and
                cleans up its uncommitted destination. User-script side effects, including successful nested derives,
                are not rolled back. Supplying a vector already assigned to any existing Trace is rejected.
            }
            propertydescriptions {
                -resultsource {
                    Read-only supplied DataSource with type calculation. Owns result traces and vectors; borrowed by
                    the evaluator.
                }
                -resultalias {
                    Read-only alias under which the result source is attached. Defaults to results and cannot be
                    detached.
                }
            }
        }
    }
    property resultsource -kind readable -get {
        return $ResultSource
    }
    property resultalias -kind readable -get {
        return $ResultAlias
    }
    variable Sources ResultSource ResultAlias ScriptNamespace Serial

    constructor {args} {
        # Creates a persistent script environment borrowing a calculation source.
        # -resultsource - source: Required live DataSource of type calculation; borrowed by the evaluator.
        # -resultalias - alias: Nonempty source lookup alias for results; defaults to results.
        #
        # Validates and automatically attaches the result source, then installs trace, derive and publish aliases in a
        # child namespace of the evaluator object namespace.
        # Synopsis: -resultsource source ?-resultalias alias?
        # Returns: The new Evaluator object command.
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
        # Checks that a source is a live DataSource object or subclass instance.
        # source - Object command to validate.
        #
        # Internal method. Invalid or destroyed objects raise an error.
        # Returns: Nothing on success.
        if {![info object isa typeof $source ::spicetracesurfer::DataSource]} {
            return -code error {Source must be a live spicetracesurfer::DataSource object}
        }
    }
    method CheckResultSource {} {
        # Checks that the borrowed result source is live and has type calculation.
        #
        # Internal method. Used before creating or publishing result data.
        # Returns: Nothing on success.
        my CheckSource $ResultSource
        if {[$ResultSource configure -type] ne {calculation}} {
            return -code error {Result source must have type calculation}
        }
    }
    method attach {args} {
        # Attaches a borrowed source under a stable evaluator-local alias.
        # source - Live DataSource object to borrow.
        # -name - alias: Optional attachment alias; defaults to the source's current name.
        #
        # Defaults to the source's current name. Empty or already attached aliases are rejected. No data is copied or
        # loaded, and changing the source name later does not change this alias.
        # Synopsis: source ?-name alias?
        # Returns: The attachment alias.
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
        # Removes an attachment without destroying its source.
        # alias - Attached source alias.
        #
        # The designated result alias cannot be detached. Unknown aliases raise an error.
        # Returns: No public result.
        if {$alias eq $ResultAlias} {
            return -code error {Cannot detach the result source alias}
        }
        if {![dict exists $Sources $alias]} {
            return -code error "Source alias '$alias' is not attached"
        }
        dict unset Sources $alias
    }
    method getSources {} {
        # Returns a snapshot of the source attachment registry.
        #
        # The returned objects are borrowed references, not copies or newly owned objects.
        # Returns: Dictionary mapping evaluator aliases to DataSource objects.
        return $Sources
    }
    method evaluate {script} {
        # Evaluates a Tcl script in the persistent session namespace.
        # script - Tcl script to execute.
        #
        # Variables and helper procedures survive subsequent calls. The trace, derive and publish commands forward to
        # this evaluator's methods. Errors propagate; earlier script side effects are not rolled back. Execution is
        # synchronous in the application's interpreter.
        # Returns: The script result, subject to normal Tcl completion semantics.
        namespace eval $ScriptNamespace $script
    }
    method trace {args} {
        # Resolves an attached waveform and returns its vector.
        # alias - Evaluator-local alias of an attached source.
        # plotname - Optional RAW plot name; omit for directly owned traces.
        # tracename - Local trace name within the source or selected plot.
        #
        # With two arguments, looks up a directly owned trace. With three, looks within a RAW plot. Rejects unattached
        # or destroyed sources. Missing names raise lookup errors. Calling the trace's getVector method can trigger lazy
        # RAW loading. Names are separate literal arguments.
        # Synopsis: alias tracename
        # Synopsis: alias plotname tracename
        # Returns: The resolved RBC vector command name.
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
        # Validates a proposed result name against the calculation source.
        # name - Proposed local trace name.
        #
        # Internal method. Requires a live calculation source and a nonempty, unused name.
        # Returns: Nothing on success.
        my CheckResultSource
        if {$name eq {}} {
            return -code error {Result trace name must not be empty}
        }
        if {[dict exists [$ResultSource getTraces] $name]} {
            return -code error "Result trace '$name' already exists"
        }
    }
    method NewVectorName {} {
        # Generates an unused internal vector name in the result source namespace.
        #
        # Internal method. Combines the evaluator's creation identifier and increasing serial, checking both command and
        # vector registries. It does not create or reserve the vector.
        # Returns: A fully qualified candidate vector name.
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
        # Evaluates an RBC expression once and publishes its result as a new trace.
        # name - Nonempty, unused trace name in the calculation source.
        # expression - RBC vector expression evaluated in the script namespace.
        # -type - physicalType: Physical data type assigned to the trace; defaults to unknown.
        # -numtype - numericType: Destination numeric type: auto (default), real or complex.
        #
        # The physical type defaults to unknown. Numeric type defaults to auto, using RBC expr with -name to preserve
        # the evaluated real or complex type without a Tcl result list.  Explicit real rejects complex results; explicit
        # complex promotes real results with zero imaginary components. Variable and command substitutions run in the
        # script namespace.
        #
        # An unused result name is required. Failed evaluation/publication cleans up the uncommitted vector. Arbitrary
        # expression side effects, including nested successful derives, remain.
        # Synopsis: name expression ?-type physicalType? ?-numtype numericType?
        # Returns: The newly registered Trace object command.
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
        # Finds an existing Trace whose assigned vector matches a command name.
        # vector - Fully qualified RBC vector command name.
        #
        # Internal method. Searches Trace instances and subclasses, including unattached sources.  Inspects assigned
        # storage only, so this ownership check never triggers lazy loading.
        # Returns: An owning Trace object, or an empty string if none is found.
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
        # Transfers an existing vector into a new trace owned by the calculation source.
        # name - Nonempty, unused trace name in the calculation source.
        # vector - Existing, unowned RBC vector with its standard command name; relative names resolve in the session
        #   namespace.
        # -type - physicalType: Physical data type assigned to the trace; defaults to unknown.
        #
        # Relative commands resolve in the session namespace even for direct method calls. Requires an existing vector
        # with its standard RBC command name; aliases/custom commands and vectors already assigned to another Trace are
        # rejected. Duplicate result names are rejected.
        #
        # Renames the vector into the result source namespace without copying samples and removes its mapped array
        # association, including watchunset-based session lifetime coupling. The old vector command name is invalid
        # after success; use the returned trace's getVector.  On an unsuccessful transfer, cleanup attempts to restore
        # the original name and mapping.
        #
        # ```tcl
        # $evaluator evaluate {
        #     rbc::vector create temporary -variable {}
        #     temporary set {1 2 3}
        #     set resultTrace [publish samples temporary -type voltage]
        #     set resultVector [$resultTrace getVector]
        # }
        # ```
        # Synopsis: name vector ?-type physicalType?
        # Returns: The newly registered Trace object command.
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
