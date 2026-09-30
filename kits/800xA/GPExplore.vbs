' 800xA exploration (READ-ONLY): walk any structure/object over local OPC DA and dump to CSV.
' Nothing is ever written to 800xA by this script.
'
' Run with 32-bit cscript:
'   C:\Windows\SysWOW64\cscript.exe //nologo GPExplore.vbs /server:ABB.AfwOpcDaSurrogate.1 /path:"[User Structure]" /out:"C:\Temp\users.csv" [/depth:2] [/mode:tree] [/maxitems:5000]
'
'   /path      levels separated by |   e.g. "[Functional Structure]|Root|Medtronic|Cell_1"  or just "[Node Administration Structure]"
'   /depth     how many levels below /path to walk (default 2)
'   /mode      full (default) = names + value + quality + data type + access rights
'              tree           = names + ItemIDs only (fast, good first look at big structures)
'   /maxitems  safety cap on rows (default 5000)
' Exit codes: 0 = OK, 1 = error, 2 = stopped at maxitems (output still valid)
Option Explicit
Dim args, opc, b, g, fso, outF, serverName, path, outPath, maxDepth, mode, maxItems, seg, nRows, handle, capped
Set args = WScript.Arguments.Named

If Not (args.Exists("server") And args.Exists("path") And args.Exists("out")) Then
    WScript.Echo "Usage: /server:<ProgID> /path:""A|B|C"" /out:<file.csv> [/depth:N] [/mode:full|tree] [/maxitems:N]"
    WScript.Quit 1
End If
serverName = args("server") : path = args("path") : outPath = args("out")
maxDepth = 2    : If args.Exists("depth") Then maxDepth = CInt(args("depth"))
mode = "full"   : If args.Exists("mode") Then mode = LCase(args("mode"))
maxItems = 5000 : If args.Exists("maxitems") Then maxItems = CLng(args("maxitems"))
nRows = 0 : handle = 0 : capped = False

Sub Fail(msg)
    WScript.Echo "ERROR: " & msg & " (0x" & Hex(Err.Number) & " " & Err.Description & ")"
    WScript.Quit 1
End Sub

Function CsvField(v)
    On Error Resume Next
    Dim s
    s = CStr(v)
    s = Replace(s, vbCrLf, "\n") : s = Replace(s, vbCr, "\n") : s = Replace(s, vbLf, "\n")
    CsvField = """" & Replace(s, """", """""") & """"
End Function

Function ValueText(v)
    On Error Resume Next
    Dim s, i
    If IsNull(v) Then
        ValueText = "<null>"
    ElseIf IsEmpty(v) Then
        ValueText = "<empty>"
    ElseIf IsArray(v) Then
        s = "["
        For i = LBound(v) To UBound(v)
            If i > LBound(v) Then s = s & "; "
            s = s & CStr(v(i))
        Next
        ValueText = s & "]"
    Else
        ValueText = CStr(v)
    End If
End Function

Function TypeText(t)
    On Error Resume Next
    Dim base, s
    base = t And &HFFF
    Select Case base
        Case 2: s = "Int16"
        Case 3: s = "Int32"
        Case 4: s = "Float"
        Case 5: s = "Double"
        Case 6: s = "Currency"
        Case 7: s = "DateTime"
        Case 8: s = "String"
        Case 11: s = "Bool"
        Case 12: s = "Variant"
        Case 16: s = "Int8"
        Case 17: s = "Byte"
        Case 18: s = "UInt16"
        Case 19: s = "UInt32"
        Case 20: s = "Int64"
        Case 21: s = "UInt64"
        Case Else: s = "Type" & base
    End Select
    If (t And &H2000) <> 0 Then s = s & "[]"
    TypeText = s
End Function

Function AccessText(a)
    On Error Resume Next
    Select Case a
        Case 1: AccessText = "R"
        Case 2: AccessText = "W"
        Case 3: AccessText = "RW"
        Case Else: AccessText = "?" & a
    End Select
End Function

Sub WriteRow(kind, rel, id, value, quality, dtype, access, errText)
    On Error Resume Next
    If nRows >= maxItems Then capped = True : Exit Sub
    outF.WriteLine CsvField(kind) & "," & CsvField(rel) & "," & CsvField(id) & "," & CsvField(value) & "," & _
                   CsvField(quality) & "," & CsvField(dtype) & "," & CsvField(access) & "," & CsvField(errText)
    nRows = nRows + 1
End Sub

Sub ReadLeaf(rel, leaf)
    On Error Resume Next
    Dim id, it, v
    If capped Then Exit Sub
    Err.Clear
    id = b.GetItemID(leaf)
    If Err.Number <> 0 Then WriteRow "Property", rel & "|" & leaf, "", "", "", "", "", "GetItemID failed" : Err.Clear : Exit Sub
    If mode = "tree" Then WriteRow "Property", rel & "|" & leaf, id, "", "", "", "", "" : Exit Sub

    handle = handle + 1
    Set it = g.OPCItems.AddItem(id, handle)
    If Err.Number <> 0 Then WriteRow "Property", rel & "|" & leaf, id, "", "", "", "", "AddItem failed: " & Err.Description : Err.Clear : Exit Sub
    it.Read 2
    If Err.Number <> 0 Then WriteRow "Property", rel & "|" & leaf, id, "", "", TypeText(it.CanonicalDataType), AccessText(it.AccessRights), "Read failed: " & Err.Description : Err.Clear : Exit Sub
    v = ValueText(it.Value)
    If Err.Number <> 0 Then v = "<unreadable type>" : Err.Clear
    WriteRow "Property", rel & "|" & leaf, id, v, it.Quality, TypeText(it.CanonicalDataType), AccessText(it.AccessRights), ""
    Err.Clear
End Sub

Sub Walk(rel, depth)
    On Error Resume Next
    Dim leaves(), branches(), x, nL, nB, i
    If capped Then Exit Sub
    Err.Clear
    b.ShowLeafs False
    ReDim leaves(b.Count) : nL = 0
    For Each x In b : leaves(nL) = x : nL = nL + 1 : Next
    For i = 0 To nL - 1 : ReadLeaf rel, leaves(i) : Next

    Err.Clear
    b.ShowBranches
    ReDim branches(b.Count) : nB = 0
    For Each x In b : branches(nB) = x : nB = nB + 1 : Next
    For i = 0 To nB - 1
        If capped Then Exit Sub
        WriteRow "Object", rel & "|" & branches(i), "", "", "", "", "", ""
        If depth < maxDepth Then
            Err.Clear
            b.MoveDown branches(i)
            If Err.Number = 0 Then
                Walk rel & "|" & branches(i), depth + 1
                b.MoveUp
            Else
                WriteRow "Object", rel & "|" & branches(i), "", "", "", "", "", "MoveDown failed"
            End If
            Err.Clear
        End If
    Next
End Sub

On Error Resume Next
Set opc = CreateObject("OPC.Automation") : If Err.Number <> 0 Then Fail "Create OPC.Automation"
opc.Connect serverName : If Err.Number <> 0 Then Fail "Connect " & serverName
Set b = opc.CreateBrowser : If Err.Number <> 0 Then Fail "CreateBrowser"
b.MoveToRoot
If UCase(path) <> "ROOT" Then
    For Each seg In Split(path, "|")
        b.MoveDown seg : If Err.Number <> 0 Then Fail "MoveDown '" & seg & "'"
    Next
End If
Set g = opc.OPCGroups.Add("Explore") : If Err.Number <> 0 Then Fail "Add group"
g.IsActive = True : g.IsSubscribed = False

Set fso = CreateObject("Scripting.FileSystemObject")
Set outF = fso.CreateTextFile(outPath, True, True)   ' Unicode, opens fine in Excel
If Err.Number <> 0 Then Fail "Create output file " & outPath
outF.WriteLine "Kind,Path,ItemID,Value,Quality,DataType,Access,Error"

WScript.Echo "Exploring '" & path & "' depth " & maxDepth & " mode " & mode & " ..."
Walk "", 0
outF.Close
opc.OPCGroups.RemoveAll
opc.Disconnect
WScript.Echo "Written: " & outPath & " (" & nRows & " rows)"
If capped Then WScript.Echo "NOTE: stopped at /maxitems:" & maxItems & " - narrow /path or lower /depth, or raise /maxitems." : WScript.Quit 2
WScript.Quit 0
