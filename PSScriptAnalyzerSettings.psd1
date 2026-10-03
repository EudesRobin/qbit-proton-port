# PSScriptAnalyzer settings of the harness (harness/Test-Lint.ps1). Every exclusion says why; a finding
# specific to one place is suppressed there instead, with a SuppressMessageAttribute and its justification.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The script and the checks are console tools: their colored output is their interface.
        'PSAvoidUsingWriteHost'
        # Private functions of scripts, not cmdlets of a module: -WhatIf and -Confirm are not offered.
        'PSUseShouldProcessForStateChangingFunctions'
        # Private functions named after the collection they handle (settings, arguments, lines);
        # GitHub Actions is a product name.
        'PSUseSingularNouns'
        # Every script requires PowerShell 7.3 or later, which reads UTF-8 files without a BOM.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
