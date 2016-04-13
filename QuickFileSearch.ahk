#NoEnv
#SingleInstance, Ignore
SetBatchLines, -1
RunAsAdmin()

Traytip, QuickFileSearch, Press Win+F to quickly search a whole drive for files

; Create Gui
Gui, Add, DropDownList, vDriveLetter, A:|B:|C:||D:|E:|F:|G:|H:|I:|J:|K:|L:|M:|N:|O:|P:|Q:|R:|S:|T:|U:|V:|W:|X:|Y:|Z:
Gui, Add, Edit, vSearchField -WantReturn
Gui, Add, Button, gSearchAction +default, Search
Gui, Add, ListView, vResultList gResultListAction w900 h400, Name
Gui, Add, Button, gOpenParentDir, Open parent directory
Gui, Add, Button, gOpenFile, Open file

;define Win+F hotkey
#f::ShowGui()

SearchAction(CtrlHwnd:="", GuiEvent:="", EventInfo:="", ErrLvl:="") {
    GuiControlGet, SearchField
    GuiControlGet, DriveLetter
    searchResults := ListMFTfiles(DriveLetter, SearchField)
    LV_Delete()
    Loop % searchResults.MaxIndex() {
        LV_Add("", searchResults[A_Index])
    }
}

OpenParentDir() {
    rowNumber := 0
    Loop {
        rowNumber := LV_GetNext(rowNumber)  ; Resume the search at the row after that found by the previous iteration.
        If !rowNumber
           Break
        LV_GetText(text, rowNumber)
        SplitPath, text, outFileName, outDir
        Run, %outDir%
    }
}

OpenFile() {
    rowNumber := 0
    Loop {
        rowNumber := LV_GetNext(rowNumber)  ; Resume the search at the row after that found by the previous iteration.
        If !rowNumber
           Break
        LV_GetText(text, rowNumber)
        SplitPath, text, outFileName, outDir
        Run, %outFileName%
    }
}

ResultListAction(CtrlHwnd:="", GuiEvent:="", EventInfo:="", ErrLvl:="") {
    If (GuiEvent = "DoubleClick")
        OpenParentDir()
}

ShowGui() {
    Gui, Show
    GuiControl,, SearchField, 
    GuiControl, Focus, SearchField
}

RunAsAdmin() {
    If !A_IsAdmin {
        Run *runAs "%A_ScriptFullPath%"
        ExitApp
    }
}

ListMFTfiles(drive, filter = "", subfolder = "", showprogress = true)
{
	;=== get root folder ("\") refnumber
	SHARE_RW := 3 ;FILE_SHARE_READ | FILE_SHARE_WRITE
	if((hRoot := DllCall("CreateFileW", wstr, "\\.\" drive "\", uint, 0, uint, SHARE_RW, PTR, 0, uint, OPEN_EXISTING := 3, uint, FILE_FLAG_BACKUP_SEMANTICS := 0x2000000, PTR, 0, PTR)) = -1)
		return
	;BY_HANDLE_FILE_INFORMATION
	;   0   DWORD dwFileAttributes;
	;   4   FILETIME ftCreationTime;
	;   12   FILETIME ftLastAccessTime;
	;   20   FILETIME ftLastWriteTime;
	;   28   DWORD dwVolumeSerialNumber;
	;   32   DWORD nFileSizeHigh;
	;   36   DWORD nFileSizeLow;
	;   40   DWORD nNumberOfLinks;
	;   44   DWORD nFileIndexHigh;
	;   48   DWORD nFileIndexLow;
	VarSetCapacity(fi, 52, 0)
	result := DllCall("GetFileInformationByHandle", PTR, hRoot, PTR, &fi, "UINT")
	DllCall("CloseHandle", PTR, hRoot, "UINT")
	if(!result)
		return
	dirdict := {}
	rootDirKey := "" ((NumGet(fi, 44) << 32) + NumGet(fi, 48))
	dirdict[rootDirKey] := {name : drive, parent : "0"}

	;=== open USN journal
	GENERIC_RW := 0xC0000000 ;GENERIC_READ | GENERIC_WRITE
	if((hJRoot := DllCall("CreateFileW", wstr, "\\.\" drive, uint, GENERIC_RW, uint, SHARE_RW, PTR, 0, uint, OPEN_EXISTING := 3, uint, 0, uint, 0, PTR)) = -1)
		return
	cb := 0
	VarSetCapacity(cujd, 16) ;CREATE_USN_JOURNAL_DATA
	NumPut(0x800000, cujd, 0, "uint64")
	NumPut(0x100000, cujd, 8, "uint64")
	if(DllCall("DeviceIoControl", PTR, hJRoot, uint, FSCTL_CREATE_USN_JOURNAL := 0x000900e7, PTR, &cujd, uint, 16, PTR, 0, uint, 0, UINTP, cb, PTR, 0, "UINT") = 0)
	{
		DllCall("CloseHandle", PTR, hJRoot, "UINT")
		return
	}

	;=== prepare data to query USN journal
	;USN_JOURNAL_DATA
	;   0   DWORDLONG UsnJournalID;
	;   8   USN FirstUsn;
	;   16   USN NextUsn;
	;   24   USN LowestValidUsn;
	;   32   USN MaxUsn;
	;   40   DWORDLONG MaximumSize;
	;   48   DWORDLONG AllocationDelta;
	VarSetCapacity(ujd, 56, 0)
	if(DllCall("DeviceIoControl", PTR, hJRoot, uint, FSCTL_QUERY_USN_JOURNAL := 0x000900f4, PTR, 0, uint, 0, PTR, &ujd, uint, 56, UINTP, cb, PTR, 0, "UINT") = 0)
	{
		DllCall("CloseHandle", PTR, hJRoot, "UINT")
		return
	}
	JournalMaxSize := NumGet(ujd, 40, "uint64")

	;=== enumerate USN journal
	cb := 0
	filedict := {}
	filedict.SetCapacity(JournalMaxSize // (128 * 10))
	dirdict.SetCapacity(JournalMaxSize // (128 * 10))
	JournalChunkSize := 0x100000
	VarSetCapacity(pData, 8 + JournalChunkSize, 0)
	;MFT_ENUM_DATA
	;   0   DWORDLONG StartFileReferenceNumber;
	;   8   USN LowUsn;
	;   16   USN HighUsn;
	VarSetCapacity(med, 24, 0)
	NumPut(NumGet(ujd, 16, "uint64"), med, 16, "uint64") ;med.HighUsn=ujd.NextUsn

	if(showprogress)
		Progress, b p0
	while(DllCall("DeviceIoControl", PTR, hJRoot, uint, FSCTL_ENUM_USN_DATA := 0x000900b3, PTR, &med, uint, 24, PTR, &pData, uint, 8 + JournalChunkSize, uintp, cb, PTR, "UINT"))
	{
		pUSN := &pData + 8
		;USN_RECORD
		;   0   DWORD RecordLength;
		;   4   WORD   MajorVersion;
		;   6   WORD   MinorVersion;
		;   8   DWORDLONG FileReferenceNumber;
		;   16   DWORDLONG ParentFileReferenceNumber;
		;   24   USN Usn;
		;   32   LARGE_INTEGER TimeStamp;
		;   40   DWORD Reason;
		;   44   DWORD SourceInfo;
		;   48   DWORD SecurityId;
		;   52   DWORD FileAttributes;
		;   56   WORD   FileNameLength;
		;   58   WORD   FileNameOffset;
		;   60   WCHAR FileName[1];
		while(cb > 8 && cb > (i := NumGet(pUSN + 0, "UINT")))
		{
			ref := "" NumGet(pUSN + 8, "uint64") ;USN.FileReferenceNumber
			refparent := "" NumGet(pUSN + 16, "uint64") ;USN.ParentFileReferenceNumber
			fn := StrGet(pUSN + 60, NumGet(pUSN + 56, "ushort") // 2, "UTF-16") ;USN.FileName
			if(NumGet(pUSN + 52) & 0x10) ;USN.FileAttributes & FILE_ATTRIBUTE_DIRECTORY
				dirdict[ref] := {name : fn, parent : refparent}
			else
				if(filter = "" || InStr(fn, filter))
					filedict[ref] := {name : fn, parent : refparent}
			i := NumGet(pUSN + 0) ;USN.RecordLength
			pUSN += i
			cb -= i
		}
		NumPut(NumGet(pData, "uint64"), med, "uint64")
		if(showprogress)
			Progress, % Round(A_index * JournalChunkSize / JournalMaxSize * 100)
	}
	DllCall("CloseHandle", PTR, hJRoot, "UINT")

	;=== connect files to parent folders
	filelist := {}
        
	if(!subfolder)
		filelist.SetCapacity(filedict.getCapacity() * 128) ;This is probably not a good idea when a subfolder is specified
	for k, v in filedict
	{
		v2 := v
		fn := v.name
		SubFolderDict := {}
		while(v2.parent)
		{
			p := dirdict[v2.parent]
			fn := p.name "\" fn
			v2 := p
		}
		if(Instr(fn, subfolder) = 1)
			filelist.Insert(fn)
	}
	if(showprogress)
		Progress, 99
	if(showprogress)
		Progress, OFF
	return filelist
}