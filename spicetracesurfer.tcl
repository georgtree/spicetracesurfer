# spicetracesurfer.tcl
# Main file of spicetracesurfer package
#
# Copyright (c) 2026 George Yashin, georgtree@gmail.com
#
# GNU GPL 3 License
# See the file "LICENSE.txt" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.

package require Tcl 9.0-
package require argparse
package require rbc::vector 0.8.1
package require rbc::graphtoolbar
package require tclsimrawreader
package require tclcsv
package require splitlayout

package provide spicetracesurfer 0.1

set dir [file dirname [file normalize [info script]]]
set libDir [file join $dir lib]
lappend auto_path $libDir
set sourceDir [file join $dir src]

source [file join $sourceDir generalClasses.tcl]


