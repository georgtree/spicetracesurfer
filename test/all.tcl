package require tcltest
namespace import ::tcltest::*
package require spicetracesurfer
set currentDir [file normalize [file dirname [info script]]]
configure {*}$argv -testdir $currentDir
runAllTests
