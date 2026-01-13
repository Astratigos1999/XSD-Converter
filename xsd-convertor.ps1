param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [Parameter(Mandatory=$true)]
    [string]$OutputDir,

    [Parameter(Mandatory=$true)]
    [string]$Namespace,

    [switch]$Recurse,
    [switch]$IncludeMetadata,
    [switch]$OneFilePerClass,
    [switch]$HardCleanOutput
)

#region GLOBAL DATA STRUCTURES

$Global:Schemas = @()
$Global:PrefixToNs = @{}
$Global:NsToSchemas = @{}
$Global:ComplexTypeRegistry = @{}
$Global:SimpleTypeRegistry = @{}
$Global:GlobalElementRegistry = @{}
$Global:NsToPrefix = @{}
$Global:ResolvedSimpleTypes = @{}
$Global:GeneratedClasses = @{}
$Global:MergedComplexTypes = @{}

function To-ValidIdentifier {
    param($name)
    if (-not $name) { return "Unnamed" }
    $clean = $name -replace "[^\w]", "_"
    if ($clean[0] -match "\d") { $clean = "_" + $clean }
    return $clean
}

function Is-ValueType {
    param($csType)
    $valueTypes = @(
        "int","long","short","sbyte",
        "decimal","double",
        "bool",
        "DateTime","TimeSpan",
        "byte","uint","ushort","ulong"
    )
    return $valueTypes -contains $csType
}

#endregion GLOBAL DATA STRUCTURES

#region SCHEMA LOADER

function Load-XsdFile {
    param($path)
    $xml = [xml](Get-Content $path)
    $schema = $xml.schema
    if (-not $schema) { return $null }
    return $schema
}

function Register-Prefixes {
    param($schema)
    foreach ($attr in $schema.Attributes) {
        if ($attr.Name -like "xmlns:*") {
            $prefix = $attr.Name.Substring(6)
            $nsUri  = $attr.Value
            if (-not $Global:PrefixToNs.ContainsKey($prefix)) {
                $Global:PrefixToNs[$prefix] = $nsUri
            }
            if (-not $Global:NsToPrefix.ContainsKey($nsUri)) {
                $Global:NsToPrefix[$nsUri] = $prefix
            }
        }
    }
}

function Register-SchemaByNamespace {
    param($schema)
    $ns = $schema.targetNamespace
    if (-not $ns) { return }
    if (-not $Global:NsToSchemas.ContainsKey($ns)) {
        $Global:NsToSchemas[$ns] = @()
    }
    $Global:NsToSchemas[$ns] += $schema
}

function Register-SchemaTypes {
    param($schema)

    foreach ($ct in $schema.complexType) {
        $name = $ct.name
        if ($name) {
            if (-not $Global:ComplexTypeRegistry.ContainsKey($name)) {
                $Global:ComplexTypeRegistry[$name] = @()
            }
            $Global:ComplexTypeRegistry[$name] += $ct
        }
    }

    foreach ($st in $schema.simpleType) {
        $name = $st.name
        if ($name) {
            if (-not $Global:SimpleTypeRegistry.ContainsKey($name)) {
                $Global:SimpleTypeRegistry[$name] = @()
            }
            $Global:SimpleTypeRegistry[$name] += $st
        }
    }

    foreach ($el in $schema.element) {
        $name = $el.name
        if ($name) {
            if (-not $Global:GlobalElementRegistry.ContainsKey($name)) {
                $Global:GlobalElementRegistry[$name] = @()
            }
            $Global:GlobalElementRegistry[$name] += $el
        }
    }
}

function Resolve-ImportsAndIncludes {
    param($schema, $basePath)

    foreach ($child in $schema.ChildNodes) {

        if ($child.LocalName -eq "import" -and $child.schemaLocation) {
            $importPath = Join-Path $basePath $child.schemaLocation
            if (Test-Path $importPath) {
                $importSchema = Load-XsdFile $importPath
                if ($importSchema) {
                    Register-Prefixes $importSchema
                    Register-SchemaByNamespace $importSchema
                    Register-SchemaTypes $importSchema
                    Resolve-ImportsAndIncludes -schema $importSchema -basePath $basePath
                }
            }
        }

        if ($child.LocalName -eq "include" -and $child.schemaLocation) {
            $includePath = Join-Path $basePath $child.schemaLocation
            if (Test-Path $includePath) {
                $includeSchema = Load-XsdFile $includePath
                if ($includeSchema) {
                    Register-Prefixes $includeSchema
                    Register-SchemaByNamespace $includeSchema
                    Register-SchemaTypes $includeSchema
                    Resolve-ImportsAndIncludes -schema $includeSchema -basePath $basePath
                }
            }
        }
    }
}

function Load-AllSchemas {
    param($path, $recurse)

    $search = @{ Path = $path; Filter = "*.xsd" }
    if ($recurse) { $search.Recurse = $true }

    $files = Get-ChildItem @search

    foreach ($file in $files) {
        Write-Host "Loading schema: $($file.Name)"
        $schema = Load-XsdFile $file.FullName
        if (-not $schema) { continue }

        Register-Prefixes $schema
        Register-SchemaByNamespace $schema
        Register-SchemaTypes $schema

        $basePath = Split-Path $file.FullName
        Resolve-ImportsAndIncludes -schema $schema -basePath $basePath

        $Global:Schemas += $schema
    }
}

#endregion SCHEMA LOADER

#region MERGE ENGINE

function Merge-Sequences {
    param($seqA, $seqB)

    if (-not $seqA) { return $seqB }
    if (-not $seqB) { return $seqA }

    $merged = $seqA.CloneNode($true)
    $existing = @{}

    foreach ($el in $merged.element) {
        $existing[$el.name] = $true
    }

    foreach ($el in $seqB.element) {
        if (-not $existing.ContainsKey($el.name)) {
            $imported = $merged.OwnerDocument.ImportNode($el, $true)
            $merged.AppendChild($imported) | Out-Null
        }
    }

    return $merged
}

function Merge-Attributes {
    param($ctA, $ctB)

    $merged = @()

    foreach ($attr in $ctA.attribute) {
        $merged += $attr
    }

    foreach ($attr in $ctB.attribute) {
        $name = $attr.name
        $exists = $false

        foreach ($a in $merged) {
            if ($a.name -eq $name) { $exists = $true; break }
        }

        if (-not $exists) { $merged += $attr }
    }

    return $merged
}

function Merge-ComplexTypePair {
    param($ctA, $ctB)

    $countA = 0
    $countB = 0

    if ($ctA.sequence) { $countA = $ctA.sequence.element.Count }
    if ($ctB.sequence) { $countB = $ctB.sequence.element.Count }

    if ($countB -gt $countA) {
        $base  = $ctB.CloneNode($true)
        $other = $ctA
    } else {
        $base  = $ctA.CloneNode($true)
        $other = $ctB
    }

    $mergedSeq = Merge-Sequences -seqA $base.sequence -seqB $other.sequence
    if ($mergedSeq) {
        $doc      = $base.OwnerDocument
        $imported = $doc.ImportNode($mergedSeq, $true)

        if ($base.sequence -and $base.sequence.ParentNode) {
            $null = $base.ReplaceChild($imported, $base.sequence)
        } else {
            $null = $base.AppendChild($imported)
        }
    }

    $mergedAttrs = Merge-Attributes -ctA $base -ctB $other

    $existingAttrs = @($base.attribute)
    foreach ($child in $existingAttrs) {
        if ($child -and $child.ParentNode) {
            $base.RemoveChild($child) | Out-Null
        }
    }

    foreach ($attr in $mergedAttrs) {
        $importedAttr = $base.OwnerDocument.ImportNode($attr, $true)
        $base.AppendChild($importedAttr) | Out-Null
    }

    return $base
}

function Merge-ComplexType {
    param($typeName)

    if ($Global:MergedComplexTypes.ContainsKey($typeName)) {
        return $Global:MergedComplexTypes[$typeName]
    }

    $defs = $Global:ComplexTypeRegistry[$typeName]
    if (-not $defs -or $defs.Count -eq 0) { return $null }

    $merged = $defs[0].CloneNode($true)

    for ($i = 1; $i -lt $defs.Count; $i++) {
        $merged = Merge-ComplexTypePair -ctA $merged -ctB $defs[$i]
    }

    $Global:MergedComplexTypes[$typeName] = $merged
    return $merged
}

#endregion MERGE ENGINE

#region SIMPLETYPE ENGINE

function Resolve-XsdType {
    param(
        $xsdType,
        [bool]$isList
    )

    if (-not $xsdType) {
        if ($isList) { return "List<string>" }
        return "string"
    }

    $localName = $xsdType
    if ($xsdType -match ":") {
        $localName = $xsdType.Split(":")[1]
    }

    if ($Global:ResolvedSimpleTypes.ContainsKey($localName)) {
        $resolved = $Global:ResolvedSimpleTypes[$localName]
        if ($isList) { return "List<$resolved>" }
        return $resolved
    }

    switch ($xsdType) {
        "xs:string"   { if ($isList) { return "List<string>" } return "string" }
        "xs:int"      { if ($isList) { return "List<int>" } return "int" }
        "xs:integer"  { if ($isList) { return "List<int>" } return "int" }
        "xs:long"     { if ($isList) { return "List<long>" } return "long" }
        "xs:short"    { if ($isList) { return "List<short>" } return "short" }
        "xs:byte"     { if ($isList) { return "List<sbyte>" } return "sbyte" }
        "xs:decimal"  { if ($isList) { return "List<decimal>" } return "decimal" }
        "xs:double"   { if ($isList) { return "List<double>" } return "double" }
        "xs:boolean"  { if ($isList) { return "List<bool>" } return "bool" }
        "xs:dateTime" { if ($isList) { return "List<DateTime>" } return "DateTime" }
        "xs:date"     { if ($isList) { return "List<DateTime>" } return "DateTime" }
        "xs:time"     { if ($isList) { return "List<TimeSpan>" } return "TimeSpan" }
    }

    if ($Global:SimpleTypeRegistry.ContainsKey($localName)) {
        if ($isList) { return "List<string>" }
        return "string"
    }

    if ($isList) { return "List<$localName>" }
    return $localName
}

function Resolve-AllSimpleTypes {

    foreach ($name in $Global:SimpleTypeRegistry.Keys) {

        if ($Global:ResolvedSimpleTypes.ContainsKey($name)) { continue }

        $defs = $Global:SimpleTypeRegistry[$name]
        if (-not $defs -or $defs.Count -eq 0) { continue }

        $st = $defs[0]

        if ($st.restriction -and $st.restriction.enumeration) {
            $enumName = To-ValidIdentifier $name
            $Global:ResolvedSimpleTypes[$name] = $enumName
            continue
        }

        $base = $null
        if ($st.restriction -and $st.restriction.base) {
            $base = $st.restriction.base
        }

        if ($base -in @("xs:int","xs:integer")) {
            $Global:ResolvedSimpleTypes[$name] = "int"
            continue
        }
        if ($base -in @("xs:decimal","xs:double")) {
            $Global:ResolvedSimpleTypes[$name] = "decimal"
            continue
        }
        if ($base -eq "xs:boolean") {
            $Global:ResolvedSimpleTypes[$name] = "bool"
            continue
        }
        if ($base -eq "xs:dateTime") {
            $Global:ResolvedSimpleTypes[$name] = "DateTime"
            continue
        }
        if ($base -eq "xs:string") {
            $Global:ResolvedSimpleTypes[$name] = "string"
            continue
        }

        if ($st.list -or $st.union) {
            $Global:ResolvedSimpleTypes[$name] = "string"
            continue
        }

        $Global:ResolvedSimpleTypes[$name] = "string"
    }
}

function Generate-AllEnums {
    param($namespace, $outputDir)

    foreach ($name in $Global:SimpleTypeRegistry.Keys) {

        $defs = $Global:SimpleTypeRegistry[$name]
        if (-not $defs -or $defs.Count -eq 0) { continue }

        $st = $defs[0]

        if (-not ($st.restriction -and $st.restriction.enumeration)) {
            continue
        }

        $enumName = To-ValidIdentifier $name

        $lines = @()
        foreach ($enumVal in $st.restriction.enumeration) {
            $raw = $enumVal.value
            $clean = ($raw -replace "[^\w]", "_")
            if ($clean[0] -match "\d") { $clean = "_" + $clean }
            $id = "${enumName}_${clean}"
            $lines += "        [XmlEnum(`"$raw`")] $id,"
        }

$code = @"
using System;
using System.Xml.Serialization;

namespace $namespace {
    [XmlType(Namespace = "`"$($st.ParentNode.targetNamespace)`"")]
    public enum $enumName {
$(($lines -join "`n"))
    }
}
"@

        $file = Join-Path $outputDir "$enumName.cs"
        Set-Content $file $code
    }
}

#endregion SIMPLETYPE ENGINE

#region CLASS GENERATOR

function Generate-ClassFromComplexType {
    param(
        $typeName,
        $ctNode,
        $namespace,
        $outputDir
    )

    if ($Global:GeneratedClasses.ContainsKey($typeName)) {
        return
    }
    $Global:GeneratedClasses[$typeName] = $true

    $fields = @()
    $props  = @()

    $targetNs = $ctNode.ParentNode.targetNamespace

    # Process <xs:sequence>
    if ($ctNode.sequence) {
        foreach ($el in $ctNode.sequence.element) {

            $propName = To-ValidIdentifier $el.name
            if (-not $propName) { continue }

            $isList = $false
            if ($el.maxOccurs -eq "unbounded") {
                $isList = $true
            }

            $isOptional = $false
            if ($el.minOccurs -eq "0") {
                $isOptional = $true
            }

            $propCsType = $null

            # Named type
            if ($el.type) {
                $propCsType = Resolve-XsdType -xsdType $el.type -isList:$isList
            }
            # Inline simpleType
            elseif ($el.simpleType -and $el.simpleType.restriction -and $el.simpleType.restriction.base) {
                $base = $el.simpleType.restriction.base

                if ($el.simpleType.restriction.enumeration) {
                    if ($isList) {
                        $propCsType = "List<string>"
                    } else {
                        $propCsType = "string"
                    }
                }
                else {
                    $propCsType = Resolve-XsdType -xsdType $base -isList:$isList
                }
            }
            # Inline list/union
            elseif ($el.simpleType -and ($el.simpleType.list -or $el.simpleType.union)) {
                if ($isList) {
                    $propCsType = "List<string>"
                } else {
                    $propCsType = "string"
                }
            }
            # Anonymous complexType
            elseif ($el.complexType) {
                $syntheticName = To-ValidIdentifier ("{0}_{1}Type" -f $typeName, $el.name)

                Generate-ClassFromComplexType -typeName $syntheticName -ctNode $el.complexType `
                    -namespace $namespace -outputDir $outputDir

                if ($isList) {
                    $propCsType = "List<$syntheticName>"
                } else {
                    $propCsType = $syntheticName
                }
            }

            # Fallback
            if (-not $propCsType) {
                if ($isList) {
                    $propCsType = "List<string>"
                } else {
                    $propCsType = "string"
                }
            }

            # Generate field + property
            $fieldName = "${propName}Field"
            $fields += "        private $propCsType $fieldName;"

            # XmlElement for list OR single
            if ($targetNs) {
                $props += "        [XmlElement(ElementName = `"$($el.name)`", Namespace = `"$targetNs`")]"
            } else {
                $props += "        [XmlElement(ElementName = `"$($el.name)`")]"
            }

            $props += "        public $propCsType $propName { get => $fieldName; set => $fieldName = value; }"
            $props += ""

            # Optional value types get a *Specified property
            if ($isOptional -and (Is-ValueType $propCsType)) {
                $specField = "${propName}FieldSpecified"
                $specProp  = "${propName}Specified"

                $fields += "        private bool $specField;"

                $props += "        [XmlIgnore]"
                $props += "        public bool $specProp { get => $specField; set => $specField = value; }"
                $props += ""
            }
        }
    }

    # Process <xs:attribute>
    foreach ($attr in $ctNode.attribute) {

        $attrName = To-ValidIdentifier $attr.name
        if (-not $attrName) { continue }

        $isOptionalAttr = $false
        if ($attr.use -eq "optional") {
            $isOptionalAttr = $true
        }

        $attrCsType = "string"
        if ($attr.type) {
            $attrCsType = Resolve-XsdType -xsdType $attr.type -isList:$false
        }

        $fieldName = "${attrName}Field"
        $fields += "        private $attrCsType $fieldName;"

        $props += "        [XmlAttribute(AttributeName = `"$($attr.name)`")]"
        $props += "        public $attrCsType $attrName { get => $fieldName; set => $fieldName = value; }"
        $props += ""

        if ($isOptionalAttr -and (Is-ValueType $attrCsType)) {
            $specField = "${attrName}FieldSpecified"
            $specProp  = "${attrName}Specified"

            $fields += "        private bool $specField;"

            $props += "        [XmlIgnore]"
            $props += "        public bool $specProp { get => $specField; set => $specField = value; }"
            $props += ""
        }
    }

    if ($fields.Count -eq 0 -and $props.Count -eq 0) {
        $props += "        // No fields detected in schema."
    }

$code = @"
using System;
using System.Collections.Generic;
using System.Xml.Serialization;
using System.CodeDom.Compiler;
using System.Diagnostics;
using System.ComponentModel;

namespace $namespace {

    [Serializable]
    [DebuggerStepThrough]
    [DesignerCategory("code")]
    [GeneratedCode("xsd", "4.8.3928.0")]
    [XmlType(TypeName = "$typeName", Namespace = "$targetNs")]
    public class $typeName {

$(($fields -join "`n"))

$(($props -join "`n"))
    }
}
"@

    $file = Join-Path $outputDir "$typeName.cs"
    Set-Content $file $code
}

function Generate-AllClasses {
    param($namespace, $outputDir)

    foreach ($typeName in $Global:ComplexTypeRegistry.Keys) {
        $merged = Merge-ComplexType $typeName
        if ($merged) {
            Generate-ClassFromComplexType -typeName $typeName -ctNode $merged `
                -namespace $namespace -outputDir $outputDir
        }
    }
}

#endregion CLASS GENERATOR

#region FILE WRITER

function Prepare-OutputDirectory {
    param($outputDir, $hardClean)

    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir | Out-Null
        return
    }

    if ($hardClean) {
        Get-ChildItem $outputDir -File | Remove-Item -Force
    }
}

function Write-AllGeneratedFiles {
    param(
        $namespace,
        $outputDir
    )

    Generate-AllEnums -namespace $namespace -outputDir $outputDir
    Generate-AllClasses -namespace $namespace -outputDir $outputDir
}

#endregion FILE WRITER

#region MAIN EXECUTION BLOCK

Write-Host ""
Write-Host "=== FINAL FORM XSD GENERATOR ==="
Write-Host "Input Path: $Path"
Write-Host "OutputDir:  $OutputDir"
Write-Host "Namespace:  $Namespace"
Write-Host ""

Prepare-OutputDirectory -outputDir $OutputDir -hardClean:$HardCleanOutput

Write-Host "Loading all XSD schemas..."
Load-AllSchemas -path $Path -recurse:$Recurse
Write-Host "Schemas loaded: $($Global:Schemas.Count)"
Write-Host ""

Write-Host "Resolving simpleTypes..."
Resolve-AllSimpleTypes
Write-Host "SimpleTypes resolved: $($Global:ResolvedSimpleTypes.Count)"
Write-Host ""

Write-Host "Merging complexTypes..."
foreach ($typeName in $Global:ComplexTypeRegistry.Keys) {
    Merge-ComplexType $typeName | Out-Null
}
Write-Host "Merged complexTypes: $($Global:MergedComplexTypes.Count)"
Write-Host ""

Write-Host "Generating enums and classes..."
Write-AllGeneratedFiles -namespace $Namespace -outputDir $OutputDir
Write-Host ""

Write-Host "=== DONE ==="
Write-Host "Output written to: $OutputDir"

#endregion MAIN EXECUTION BLOCK