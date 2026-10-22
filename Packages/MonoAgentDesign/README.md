# MonoAgentDesign seam

This iOS-only package starts with one value token and a Swift Testing test. It has no
Kit, Store or network dependency. C5 can add source/test files without project edits.
The package test directory is also a file-system-synchronized source root of the app
unit-test target, so these same tests run in the shared iOS test plan. The linked-package
scheme otherwise does not discover package tests when invoked through the app project.
