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
                value intact; a multi-property configure call is not transactional. Loaded RAW/CSV acquisition
                settings are locked. The source display name and trace axis association remain editable.

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
                addTrace rejects a different object with an existing name before changing either object; registering
                the identical object again is a no-op. Failed registration leaves the incoming trace caller-owned.
                A trace cannot be registered with two owners. Calculation metadata remains editable, but changing
                a registered name does not rekey its dictionary.

                ## File protection and reload
                Loaded RAW/CSV sources lock type, filepath, filetype, dialect and all CSV settings. Their plot
                names/indices/source links, trace metadata/vector references and collection membership are sealed.
                Public destroy of sealed child objects is rejected; destroy the source or use reload instead.
                CSV vectors are protected immediately and RAW vectors when first loaded, using RBC `readonly true`.
                RBC 0.8.1 is required. This is accidental-change protection, not a security boundary: users can
                deliberately unlock, rename or destroy an RBC vector or bypass TclOO setters via introspection.

                Construction and reload share private loaders that return a staging dictionary containing plain
                metadata records, temporary vectors and a RAW reader when applicable. Staging creates no DataSource,
                RawPlot or Trace objects. Temporary vectors live in a private namespace; adopted vectors are renamed
                into their owning Trace namespace. Cleanup releases all resources not transferred during commit.

                `$source reload` stages replacement data, then updates matching plots and traces in place. Plots match
                by plot key/index; traces match by local name, so CSV column reordering preserves identity. Matching
                Trace objects retain axis assignments. Loaded same-type vectors are updated using dup and retain their
                identity and graph connections. Numeric-type changes replace the vector only; reacquire that vector
                reference and rebind its consumers. Added entries are created; removed entries are destroyed. Existing
                calculation results are not recalculated. Source identity and acquisition settings are preserved.

                CSV reload stages all samples. RAW reload stages metadata and samples only for matching traces with
                loaded vectors; other traces remain lazy and sample errors may surface on a later getVector. Staging
                failures preserve existing objects and loaded vectors. Temporary memory includes replacement data for
                loaded traces. Commit-time copy/allocation errors do not roll back earlier updates, and notifications
                are not batched across vectors. Protection is restored after each in-place copy, including errors.

                RAW readers open the original file directly: there is no temporary copy. Keep that file unchanged while
                using unloaded traces. Before and after lazy reads, file size, timestamps and available file identity
                fields are checked; a detected change requires reload. These checks are best effort, not a content hash
                or a guarantee against concurrent writes. A failed reload cannot restore overwritten file bytes, so
                unloaded old traces may no longer be readable. Already loaded vectors remain usable.
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
                    Tcl boolean indicating a header record; default true. Locked after file acquisition.
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
        my CheckMetadataWritable
        classvariable SourceTypes
        if {$value ni $SourceTypes} {
            return -code error "Source type '$value' is not one of the allowed types: [join $SourceTypes {, }]"
        } else {
            set type $value
        }
    }
    property filetype -set {
        my CheckMetadataWritable
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
        my CheckMetadataWritable
        if {$type ne {file}} {
            return -code error "To set filepath type must be file, but type is '[my configure -type]'"
        } else {
            set filepath $value
        }
    }
    property dialect -set {
        my CheckMetadataWritable
        set dialect $value
    }
    property csvbatchsize -set {
        my CheckMetadataWritable
        if {![string is integer -strict $value] || $value <= 0} {
            return -code error {CSV batch size must be a positive integer}
        }
        set csvbatchsize $value
    }
    property csvdelimiter -set {
        my CheckMetadataWritable
        if {[string length $value] != 1 || ![string is ascii -strict $value]} {
            return -code error {CSV delimiter must be a single ASCII character}
        }
        set csvdelimiter $value
    }
    property csvencoding -set {
        my CheckMetadataWritable
        # Asking Tcl to convert an empty string validates the encoding name
        # without opening a file, and supports lazily loaded encodings.
        if {[catch {encoding convertfrom $value {}} message]} {
            return -code error "Invalid CSV encoding '$value': $message"
        }
        set csvencoding $value
    }
    property csvheader -set {
        my CheckMetadataWritable
        if {![string is boolean -strict $value]} {
            return -code error {CSV header flag must be a boolean}
        }
        set csvheader $value
    }
    property csvnametemplate -set {
        my CheckMetadataWritable
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
    variable FileLocked RawFileStamp RawPath StageSerial
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
        set FileLocked 0
        set StageSerial 0
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
        try {
            if {$type eq {file} && $filetype in {raw csv}} {
                package require rbc::vector 0.8.1
                if {$filetype eq {raw}} {
                    my configure -dialect [dict get $arguments dialect]
                }
                set stage [my StageFile]
                try {
                    my CommitStage stage
                    my SealFileData
                } finally {
                    my DisposeStage $stage
                }
            }
        } on error {message options} {
            my DisposeData
            return -options $options $message
        }
    }
    destructor {
        # Destroys owned traces and raw plots, then closes an existing RAW reader.
        #
        # Registered objects and vectors must not be shared between owners.
        # Returns: Nothing.
        my DisposeData
    }
    method CheckMetadataWritable {} {
        # Rejects changes to the acquisition settings of a loaded file source.
        #
        # Returns: Nothing on success; an error when metadata is locked.
        if {[info exists FileLocked] && $FileLocked} {
            return -code error {File source metadata is locked; use reload to reread its data}
        }
    }
    method DisposeData {} {
        # Releases owned payload objects and the RAW reader, including partial loads.
        #
        # Internal cleanup is allowed to dispose locked children.
        # Returns: Nothing.
        foreach collection {Traces RawPlots} {
            if {[info exists $collection]} {
                dict for {key object} [set $collection] {
                    if {[info object isa object $object]} {
                        catch {namespace eval [info object namespace $object] {my DisposeOwned}}
                    }
                }
                set $collection {}
            }
        }
        if {[info exists FileHandle]} {
            catch {$FileHandle close}
            unset FileHandle
        }
        unset -nocomplain RawFileStamp RawPath
    }
    method SealFileData {} {
        # Locks registered metadata and any already loaded file vectors.
        #
        # Returns: Nothing.
        dict for {key object} $Traces {
            namespace eval [info object namespace $object] {my SealFileData}
        }
        dict for {key object} $RawPlots {
            namespace eval [info object namespace $object] {my SealFileData}
        }
        set FileLocked 1
    }
    method reload {} {
        # Stages replacement data before updating the source's owned objects.
        #
        # Matching plot keys and local trace names preserve object identity and axis assignments.
        # Loaded matching vectors of the same numeric type are updated with dup and retain identity.
        # A numeric-type change replaces the vector, requiring consumers to reacquire its reference.
        # CSV stages all samples. RAW stages samples only for matching traces already loaded in this source;
        # other traces stay lazy. All required reads finish before existing data is changed.
        # Read failures preserve objects and loaded vectors, but cannot restore externally overwritten RAW bytes.
        # Commit-time copy/allocation errors are propagated without rollback of earlier updates. Notifications
        # are not batched across vectors. The owner restores vector protection even when a copy fails.
        # Returns: This DataSource object.
        if {($type ne {file}) || ($filetype ni {raw csv})} {
            return -code error {Reload requires a RAW or CSV file source}
        }
        set stage [my StageFile]
        try {
            my CommitStage stage
            return [self]
        } finally {
            my DisposeStage $stage
        }
    }
    method NewStage {} {
        # Allocates a private staging dictionary and a namespace for temporary vector commands.
        #
        # Internal schema: traces maps names to records containing type and optional vector; plots maps
        # keys to records containing index and traces. Reader, rawpath and rawstamp describe RAW input.
        # No DataSource, RawPlot or Trace objects are created. The caller must use DisposeStage.
        # Returns: A staging dictionary with namespace, traces, plots and reader fields.
        set ns [info object namespace [self]]::stage[incr StageSerial]
        namespace eval $ns {}
        return [dict create namespace $ns traces {} plots {} reader {}]
    }
    method DisposeStage {stage} {
        # Releases resources still owned by a staging dictionary.
        # stage - Dictionary returned by NewStage or StageFile.
        #
        # Transferred vectors have been renamed outside the temporary namespace. Commit clears reader
        # when transferring it to the source. Safe for partial loads and after partial commit errors.
        # Returns: Nothing.
        set reader [dict get $stage reader]
        if {$reader ne {}} {
            catch {$reader close}
        }
        set ns [dict get $stage namespace]
        # Deleting the namespace deletes remaining vector commands and their RBC storage.
        if {[namespace exists $ns]} {
            namespace delete $ns
        }
    }
    method StageFile {} {
        # Reads replacement data into a dedicated staging dictionary.
        #
        # Internal method shared by construction and reload. CSV stages every column; RAW stages headers
        # and samples only for matching traces whose vectors are already loaded. Failure cleans up all
        # staging resources before returning an error and leaves existing objects untouched.
        # Returns: A complete staging dictionary owned by the caller; dispose it with DisposeStage.
        set stage [my NewStage]
        try {
            if {$filetype eq {raw}} {
                my StageRaw stage
            } else {
                my StageCsv stage
            }
            return $stage
        } on error {message options} {
            my DisposeStage $stage
            return -options $options $message
        }
    }
    method CommitStage {stageVar} {
        # Updates owned objects from prepared metadata and vectors without reading samples.
        # stageVar - Caller variable holding a staging dictionary; reader ownership is updated in place.
        #
        # Internal method. Matching objects survive; new entries are constructed and removed entries
        # are destroyed. Copy/allocation errors propagate without rollback of earlier updates.
        # Returns: Nothing. The caller must dispose the remaining stage in a finally block.
        upvar 1 $stageVar stage
        my MergeTraces [self] [dict get $stage traces]
        set incomingPlots [dict get $stage plots]
        dict for {key replacement} $incomingPlots {
            if {[dict exists $RawPlots $key]} {
                set current [dict get $RawPlots $key]
            } else {
                set current [::spicetracesurfer::RawPlot new $key [dict get $replacement index] [self]]
                dict set RawPlots $key $current
                namespace eval [info object namespace $current] {my SealFileData}
            }
            my MergeTraces $current [dict get $replacement traces]
            set [info object namespace $current]::index [dict get $replacement index]
            namespace eval [info object namespace $current] {my SealFileData}
        }
        dict for {key current} $RawPlots {
            if {![dict exists $incomingPlots $key]} {
                namespace eval [info object namespace $current] {my DisposeOwned}
                dict unset RawPlots $key
            }
        }
        set reader [dict get $stage reader]
        if {$reader ne {}} {
            set oldHandle {}
            if {[info exists FileHandle]} {
                set oldHandle $FileHandle
            }
            set FileHandle $reader
            set RawPath [dict get $stage rawpath]
            set RawFileStamp [dict get $stage rawstamp]
            dict set stage reader {}
            if {$oldHandle ne {}} {
                catch {$oldHandle close}
            }
        }
    }
    method MergeTraces {owner incoming} {
        # Commits staged trace records into an existing source or plot.
        # owner - Surviving DataSource or RawPlot that owns the destination collection.
        # incoming - Dictionary mapping trace names to metadata records with type and optional vector.
        #
        # Internal method. Matching traces are updated; only new names create Trace objects. A newly
        # created trace is cleaned up if its initialization fails. Removed names are disposed by the owner.
        # Returns: Nothing. Commit errors propagate and do not roll back earlier updates.
        set ownerNs [info object namespace $owner]
        dict for {key replacement} $incoming {
            if {[dict exists [set ${ownerNs}::Traces] $key]} {
                set current [dict get [set ${ownerNs}::Traces] $key]
                namespace eval [info object namespace $current] [list my UpdateFrom $replacement]
            } else {
                set current [::spicetracesurfer::Trace new -- $key [dict get $replacement type] [self]]
                try {
                    set traceNs [info object namespace $current]
                    set ${traceNs}::rawplot [expr {$owner eq [self] ? {} : $owner}]
                    set ${traceNs}::RegistrationOwner $owner
                    namespace eval $traceNs [list my UpdateFrom $replacement]
                    namespace eval $traceNs {my SealFileData}
                    dict set ${ownerNs}::Traces $key $current
                } on error {message options} {
                    namespace eval [info object namespace $current] {my DisposeOwned}
                    return -options $options $message
                }
            }
        }
        dict for {key current} [set ${ownerNs}::Traces] {
            if {![dict exists $incoming $key]} {
                namespace eval [info object namespace $current] {my DisposeOwned}
                dict unset ${ownerNs}::Traces $key
            }
        }
    }
    method StageRaw {stageVar} {
        # Stages RAW metadata and any samples required by already loaded matching traces.
        # stageVar - Caller variable holding a staging dictionary, updated in place.
        #
        # Opens the original file directly. Initial loading and new traces remain lazy. Generated vector
        # names avoid using file variable names as command syntax. File signatures bracket staging reads.
        # Returns: Nothing. StageFile owns failure cleanup, including partially created vectors.
        upvar 1 $stageVar stage
        set path [file normalize $filepath]
        dict set stage rawpath $path
        dict set stage rawstamp [my RawSignature $path]
        set reader [tclsimrawreader::openraw -dialect $dialect -output vector -ifexists error $path]
        dict set stage reader $reader
        set vectorIndex 0
        foreach plotInfo [$reader plots] {
            set index [dict get $plotInfo index]
            set key plot$index
            if {[dict exists $stage plots $key]} {
                return -code error "Duplicate RAW plot '$key'"
            }
            set traces {}
            foreach variable [dict get [$reader header -plot $index] variables] {
                set traceName [dict get $variable name]
                if {[dict exists $traces $traceName]} {
                    return -code error "Duplicate RAW variable '$traceName' in '$key'"
                }
                set record [dict create type [dict get $variable type]]
                if {[dict exists $RawPlots $key]} {
                    set oldTraces [[dict get $RawPlots $key] getTraces]
                    if {[dict exists $oldTraces $traceName]} {
                        set traceNs [info object namespace [dict get $oldTraces $traceName]]
                        if {[info exists ${traceNs}::vector] && ([set ${traceNs}::vector] ne {})} {
                            set vector [$reader vector -plot $index $traceName\
                                                -name [dict get $stage namespace]::v[incr vectorIndex]]
                            $vector readonly true
                            dict set record vector $vector
                        }
                    }
                }
                dict set traces $traceName $record
            }
            dict set stage plots $key [dict create index $index traces $traces]
        }
        if {[my RawSignature $path] ne [dict get $stage rawstamp]} {
            return -code error -errorcode {SPICETRACESURFER RAW CHANGED}\
                    {RAW file changed during staging; retry reload with a stable file}
        }
    }
    method RawSignature {{path {}}} {
        # Reads inexpensive filesystem metadata for a RAW path.
        # path - Optional filename; defaults to the current source RAW path.
        #
        # Internal method. Excludes access time, which reads may change. File identity fields are platform
        # dependent and timestamps may have coarse resolution; this is not a content fingerprint.
        # Returns: A list of available identity, size and timestamp fields; errors if the path is unavailable.
        if {$path eq {}} {
            set path $RawPath
        }
        file stat $path stat
        set signature {}
        foreach field {dev ino size mtime ctime} {
            if {[info exists stat($field)]} {
                lappend signature $field $stat($field)
            }
        }
        return $signature
    }
    method CheckRawUnchanged {} {
        # Rejects further lazy reads after a detected change to the RAW file.
        #
        # Internal method. Does not read file contents. Loaded vectors need no filesystem check.
        # Returns: Nothing on success; an error if the path is missing or its signature differs.
        if {[catch {my RawSignature} current] || ($current ne $RawFileStamp)} {
            return -code error -errorcode {SPICETRACESURFER RAW CHANGED}\
                    {RAW file changed or is unavailable; reload the source before reading unloaded traces}
        }
    }
    method StageCsv {stageVar} {
        # Parses numeric CSV data in batches into staged column vectors and metadata.
        # stageVar - Caller variable holding a staging dictionary, updated in place.
        #
        # Shared by construction and reload. Validates headers, row widths and numeric cells before commit.
        # The parser/channel are closed here; StageFile cleans up staged vectors if any operation fails.
        # Returns: Nothing. The stage contains trace records but no Trace objects.
        upvar 1 $stageVar stage
        set channel [open $filepath r]
        set reader {}
        set vectors {}
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
                set vecName [dict get $stage namespace]::csvColumn$i
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
            foreach header $headers vec $vectors {
                $vec readonly true
                dict set stage traces $header [dict create type unknown vector $vec]
            }
            # Close input before returning a successful stage.
            $reader destroy
            set reader {}
            close $channel
            set channel {}
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
        # collision policy. Called by Trace.getVector for lazy loading. Checks the original file signature
        # before and after reading; a detected change discards the new vector and requires reload.
        # Returns: The RBC vector name returned by the RAW reader.
        if {$type eq {file}} {
            if {$filetype eq {raw}} {
                my CheckRawUnchanged
                set result [$FileHandle vector -plot $plot $name -name ${namespace}::$name]
                try {
                    my CheckRawUnchanged
                } on error {message options} {
                    catch {rbc::vector destroy $result}
                    return -options $options $message
                }
                return $result
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
        # Rejects a different trace with the same name without changing either object. Re-registering
        # the identical object is a no-op. New membership requires editable metadata and matching source.
        # Failed registration leaves the incoming object caller-owned; existing traces are never destroyed.
        # Returns: No public result.
        if {![info object isa typeof $trace ::spicetracesurfer::Trace]} {
            return -code error {Expected a live Trace object}
        }
        set key [$trace configure -name]
        if {[dict exists $Traces $key]} {
            if {[dict get $Traces $key] eq $trace} {
                return
            }
            return -code error "Trace '$key' already exists"
        }
        my CheckMetadataWritable
        if {[$trace configure -source] ne [self]} {
            return -code error {Trace belongs to a different data source}
        }
        set traceNs [info object namespace $trace]
        if {[info exists ${traceNs}::RegistrationOwner] && ([set ${traceNs}::RegistrationOwner] ne [self])} {
            return -code error {Trace is already registered with another owner}
        }
        if {[info exists ${traceNs}::rawplot] && ([set ${traceNs}::rawplot] ne {}) &&\
                    ([set ${traceNs}::rawplot] ne {})} {
            return -code error {Trace already belongs to a different raw plot}
        }
        $trace configure -rawplot {}
        set ${traceNs}::RegistrationOwner [self]
        dict set Traces $key $trace
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

                The source constructs plots when committing staged RAW metadata. Plot construction alone does not read
                sample vectors. A plot's fullname combines its source name and local plot name for display; it is not an
                unambiguous serialization of unrestricted hierarchical names.

                Loaded file plots have locked names, indices, source references and trace membership. Public destroy
                is rejected after sealing. Source destruction or reload disposes plots and their registered traces.
                A duplicate trace name is rejected; registering the same object again is a no-op. Trace and vector
                ownership must be unique.
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
    property name -set {
        my CheckMetadataWritable
        set name $value
    }
    property index -set {
        my CheckMetadataWritable
        set index $value
    }
    property source -set {
        my CheckMetadataWritable
        if {![info object class $value ::spicetracesurfer::DataSource]} {
            return -code error "Source must be an object of class ::spicetracesurfer::DataSource"
        } else {
            set source $value
        }
    }
    property fullname -kind readable -get {
        return "[$source configure -name].$name"
    }
    variable name fullname source index Traces
    variable FileLocked
    method CheckMetadataWritable {} {
        # Rejects public metadata or membership changes after file data is sealed.
        #
        # Returns: Nothing on success.
        if {[info exists FileLocked] && $FileLocked} {
            return -code error {File-backed metadata is locked}
        }
    }
    method destroy {} {
        # Destroys an editable object. Locked file children are disposed by their source.
        #
        # Returns: Nothing.
        my CheckMetadataWritable
        next
    }
    method DisposeOwned {} {
        # Allows the owner to release this object during source destruction or reload.
        #
        # Returns: Nothing.
        set FileLocked 0
        my destroy
    }
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
                    namespace eval [info object namespace $trace] {my DisposeOwned}
                }
            }
        }
    }
    method addTrace {trace} {
        # Registers a trace and assigns this plot as its rawplot.
        # trace - Trace object indexed by its current name.
        #
        # Duplicate names belonging to another object are errors; registering the same object is a no-op.
        # Rejects changes to a sealed file plot and mismatched or already registered owners before mutation.
        # On failure the incoming trace remains caller-owned and unchanged.
        # Returns: No public result.
        if {![info object isa typeof $trace ::spicetracesurfer::Trace]} {
            return -code error {Expected a live Trace object}
        }
        set key [$trace configure -name]
        if {[dict exists $Traces $key]} {
            if {[dict get $Traces $key] eq $trace} {
                return
            }
            return -code error "Trace '$key' already exists"
        }
        my CheckMetadataWritable
        if {[$trace configure -source] ne $source} {
            return -code error {Trace belongs to a different data source}
        }
        set traceNs [info object namespace $trace]
        if {[info exists ${traceNs}::RegistrationOwner] && ([set ${traceNs}::RegistrationOwner] ne [self])} {
            return -code error {Trace is already registered with another owner}
        }
        if {[info exists ${traceNs}::rawplot] && ([set ${traceNs}::rawplot] ne {}) &&\
                    ([set ${traceNs}::rawplot] ne [self])} {
            return -code error {Trace already belongs to a different raw plot}
        }
        $trace configure -rawplot [self]
        set ${traceNs}::RegistrationOwner [self]
        dict set Traces $key $trace
    }
    method SealFileData {} {
        # Seals file metadata and all registered traces.
        #
        # Returns: Nothing.
        dict for {key trace} $Traces {
            namespace eval [info object namespace $trace] {my SealFileData}
        }
        set FileLocked 1
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

                File-backed traces reject changes to name, type, numtype, length, source, rawplot and vector after
                loading. The owner may internally assign the first lazy RAW vector, already marked readonly.
                Axis remains editable. Public destruction of sealed traces is rejected; their owner handles cleanup.
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
    property name -set {
        my CheckMetadataWritable
        set name $value
    }
    property fullname -kind readable -get {
        if {[info exists rawplot] && $rawplot ne {}} {
            return "[$rawplot configure -fullname].$name"
        }
        return "[$source configure -name].$name"
    }
    property type -set {
        my CheckMetadataWritable
        set type $value
    }
    property numtype -get {
        if {[info exists vector]} {
            return [$vector type]
        } else {
            return $numtype
        }
    } -set {
        my CheckMetadataWritable
        if {[info exists vector]} {
            set numtype [$vector type]
        } else {
            set numtype $value
        }
    }
    property vector -set {
        my CheckMetadataWritable
        set vector $value
    }
    property length -get {
        if {[info exists vector]} {
            return [$vector length]
        } else {
            return $length
        }
    } -set {
        my CheckMetadataWritable
        if {[info exists vector]} {
            set length [$vector length]
        } else {
            set length $value
        }
    }
    property source -set {
        my CheckMetadataWritable
        if {![info object class $value ::spicetracesurfer::DataSource]} {
            return -code error "Source must be an object of class ::spicetracesurfer::DataSource"
        } else {
            set source $value
        }
    }
    property rawplot -set {
        my CheckMetadataWritable
        set rawplot $value
    }
    property axis
    variable name fullname type numtype length vector source rawplot axis
    variable FileLocked RegistrationOwner
    method CheckMetadataWritable {} {
        # Rejects public metadata or membership changes after file data is sealed.
        #
        # Returns: Nothing on success.
        if {[info exists FileLocked] && $FileLocked} {
            return -code error {File-backed metadata is locked}
        }
    }
    method destroy {} {
        # Destroys an editable object. Locked file children are disposed by their source.
        #
        # Returns: Nothing.
        my CheckMetadataWritable
        next
    }
    method DisposeOwned {} {
        # Allows the owner to release this object during source destruction or reload.
        #
        # Returns: Nothing.
        set FileLocked 0
        my destroy
    }
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
    method SealFileData {} {
        # Protects metadata and already loaded vector data using RBC readonly.
        #
        # Returns: Nothing.
        if {[info exists vector] && ($vector ne {})} {
            $vector readonly true
        }
        set FileLocked 1
    }
    method UpdateFrom {replacement} {
        # Updates this trace from a staged metadata record without public metadata setters.
        # replacement - Dictionary containing type and an optional fully populated readonly vector.
        #
        # Internal owner operation. Preserves this object and its axis association. Same-type vectors are
        # copied in place; different types transfer the staged vector into this object's namespace and
        # destroy the old vector. An unloaded replacement keeps an unloaded destination lazy.
        # Returns: Nothing. Copy failures restore readonly protection but do not undo prior source updates.
        if {[dict exists $replacement vector]} {
            set incoming [dict get $replacement vector]
            if {[info exists vector] && ($vector ne {}) && ([$vector type] eq [$incoming type])} {
                $vector readonly false
                try {
                    $incoming dup $vector
                } finally {
                    $vector readonly true
                }
            } else {
                # Staging namespace serials are unique for this source across repeated reloads.
                set suffix [namespace tail [namespace qualifiers $incoming]]_[namespace tail $incoming]
                # Do not retain an array mapping in the namespace that staging will delete.
                $incoming variable {}
                set adopted [rbc::vector rename $incoming [info object namespace [self]]::reload_$suffix]
                set previous {}
                if {[info exists vector]} {
                    set previous $vector
                }
                set vector $adopted
                if {$previous ne {}} {
                    rbc::vector destroy $previous
                }
            }
        }
        set type [dict get $replacement type]
        unset -nocomplain numtype length
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
            set loaded [$source readRawVector [$rawplot configure -index] $name [info object namespace [self]]]
            try {
                if {[info exists FileLocked] && $FileLocked} {
                    $loaded readonly true
                }
            } on error {message options} {
                rbc::vector destroy $loaded
                return -options $options $message
            }
            set vector $loaded
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
