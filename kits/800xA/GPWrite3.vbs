' 800xA General Property read/write via local OPC DA (VBScript, built into Windows)
' Exit codes: 0 = OK, 1 = error (step shown), 3 = write accepted but read-back differs
' Run with 32-bit cscript:
'   C:\Windows\SysWOW64\cscript.exe //nologo "%USERPROFILE%\Downloads\GPWrite.vbs" /server:ABB.AfwOpcDaSurrogate.1 /browse:ROOT
'
'   /browse:ROOT                 list branches/leaves at the top
'   /browse:"A|B|C"              list under A > B > C  (| between levels)
'   /find:URL1                   flat search for items containing text
'   /item:"<ItemID>"             read
'   /item:"<ItemID>" /value:"x"  write + read back
Option Explicit

Dim args, serverName, stepName
Set args = WScript.Arguments.Named

Sub Stp(t)
    stepName = t
    WScript.Echo "  [step] " & t
End Sub

Sub Chk(num, desc)
    If num <> 0 Then
        WScript.Echo "ERROR at step '" & stepName & "': 0x" & Hex(num) & " " & desc
        Err.Clear
        On Error Resume Next
        opc.Disconnect
        WScript.Quit 1
    End If
End Sub

Dim opc, b, i, n, leaf, id, seg, hits, g, it, v, rc
rc = 0
On Error Resume Next

Stp "Create OPC.Automation"
Set opc = CreateObject("OPC.Automation")
Chk Err.Number, Err.Description
If Not args.Exists("server") Then
    WScript.Echo "OPC DA servers:"
    For Each v In opc.GetOPCServers
        WScript.Echo "  " & v
    Next
    WScript.Quit 0
End If

serverName = args("server")
Stp "Connect " & serverName
opc.Connect serverName
Chk Err.Number, Err.Description
WScript.Echo "Connected."

If args.Exists("browse") Or args.Exists("find") Then
    Stp "CreateBrowser"
    Set b = opc.CreateBrowser
    Chk Err.Number, Err.Description
    If b Is Nothing Then
        WScript.Echo "RESULT: server returned no browser (browsing not supported)."
        opc.Disconnect
        WScript.Quit 1
    End If
    WScript.Echo "Namespace organization: " & b.Organization & "  (1=hierarchical, 2=flat)"
    Err.Clear

    If args.Exists("browse") Then
        Stp "MoveToRoot"
        b.MoveToRoot
        Chk Err.Number, Err.Description
        If UCase(args("browse")) <> "ROOT" Then
            For Each seg In Split(args("browse"), "|")
                Stp "MoveDown '" & seg & "'"
                b.MoveDown seg
                Chk Err.Number, Err.Description
            Next
        End If

        Stp "ShowBranches"
        b.ShowBranches
        Chk Err.Number, Err.Description
        n = b.Count
        WScript.Echo "Branches (" & n & "):"
        For Each leaf In b
            WScript.Echo "  [B] " & leaf
        Next
        Err.Clear

        Stp "ShowLeafs"
        b.ShowLeafs False
        Chk Err.Number, Err.Description
        n = b.Count
        WScript.Echo "Leaves (" & n & "):"
        For Each leaf In b
            id = b.GetItemID(leaf)
            If Err.Number <> 0 Then id = "?" : Err.Clear
            WScript.Echo "  [L] " & leaf & "   ->  ItemID: " & id
        Next
        Err.Clear
    Else
        Stp "ShowLeafs (flat)"
        b.ShowLeafs True
        Chk Err.Number, Err.Description
        n = b.Count
        WScript.Echo "Leaves scanned: " & n & ". Matches for '" & args("find") & "':"
        hits = 0
        For Each leaf In b
            id = b.GetItemID(leaf)
            If Err.Number <> 0 Then id = leaf : Err.Clear
            If InStr(1, id, args("find"), vbTextCompare) > 0 Then
                WScript.Echo "  " & id
                hits = hits + 1
            End If
        Next
        WScript.Echo "Matches: " & hits
        If n = 0 Then WScript.Echo "Flat search returned nothing - use /browse:ROOT instead."
    End If

ElseIf args.Exists("item") Then
    Stp "Add group"
    Set g = opc.OPCGroups.Add("GPTest")
    Chk Err.Number, Err.Description
    g.IsActive = True
    g.IsSubscribed = False

    Stp "AddItem " & args("item")
    Set it = g.OPCItems.AddItem(args("item"), 1)
    Chk Err.Number, Err.Description
    Stp "Read"
    it.Read 2
    Chk Err.Number, Err.Description
    WScript.Echo "Before: value='" & it.Value & "' quality=" & it.Quality

    If args.Exists("value") Then
        Stp "Write"
        it.Write args("value")
        Chk Err.Number, Err.Description
        WScript.Sleep 500
        Stp "Read back"
        it.Read 2
        Chk Err.Number, Err.Description
        WScript.Echo "After:  value='" & it.Value & "' quality=" & it.Quality
        If CStr(it.Value) = args("value") Then
            WScript.Echo "RESULT: WRITE SUCCEEDED"
        Else
            WScript.Echo "RESULT: write accepted but read-back differs"
            rc = 3
        End If
    End If
    opc.OPCGroups.RemoveAll
Else
    WScript.Echo "Use /browse:, /find:, or /item:"
End If

opc.Disconnect
WScript.Quit rc
