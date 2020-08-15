-- Exports Safari's saved passwords to a CSV file formatted for use with the convert_to_1p4's csv converter
--
-- Version 1.6
-- mike (at) cappella (dot) us
--

use AppleScript version "2.5" -- runs on 10.11 (El Capitan) and later				
use scripting additions

-- Avoid a bug in Safari 13.x which prematurely closes the passwords dialog while it is active
if application "Safari" is running then
	set theResult to display dialog "Safari must be quit before this script can run.

Quit Safari?"
	if (button returned of theResult) is "Cancel" then
		error number -128
	end if
	tell application "Safari" to quit
end if

set csv_filepath to (path to desktop as text) & "pm_export.csv"

set invokedBy to ""
tell application "System Events"
	set invokedBy to get the name of the current application
	activate "Safari"
end tell

set Entries to {}
set Entries to FetchEntries()

set theResult to write_csv_file(Entries, csv_filepath)
if not theResult then
	display dialog "There was an error writing the data!"
	error number -128
end if

tell application "System Events" to tell application process "Safari"
	keystroke "w" using {command down}
end tell

tell application "Finder"
	activate
	make new Finder window
	set target of Finder window 1 to path to desktop
	reveal csv_filepath
end tell

tell application "System Events" to tell application process invokedBy
	set frontmost to true
	
	display dialog "All done!

There is now a file on your Desktop named:

pm_export.csv

You may now convert it to a 1PIF for import into 1Password using the csv converter in the converter suite."
end tell

-- handlers
on FetchEntries()
	set tableEntries to {}
	tell application "Safari"
		activate
	end tell
	
	tell application "System Events" to tell application process "Safari"
		set frontmost to true
		keystroke "," using {command down}
		set tb to toolbar 1 of window 1
		set buttonName to (name of button 4 of tb as string)
		click button 4 of tb
		set theResult to display dialog "Please unlock " & buttonName & " and press Continue when unlocked" buttons {"Cancel", "Continue"} default button "Continue"
		if (button returned of theResult) is "Cancel" then
			error number -128
		end if
		tell application "System Events" to tell application process "Safari"
			set frontmost to true
		end tell
		
		local prefsWin
		set prefsWin to window 1
		set theTable to table 1 of scroll area 1 of group 1 of group 1 of prefsWin
		set nRows to the count of rows of table 1 of scroll area 1 of group 1 of group 1 of prefsWin
		-- say "Dialog has " & nRows & "rows."
		
		local row_index, failed_rows
		set row_index to 1
		set failed_rows to 0
		repeat while row_index ² nRows
			-- say "Row " & row_index
			
			local myRow, row_open_attempts
			local theSite, theName, theUser, thePass, theURLs, urlList, rowValues, theSheet
			set {theTitle, theSite, theUser, thePass, theURLs} to {"Untitled", "", "", "", ""}
			set urlList to {}
			set theSheet to 0
			set row_open_attempts to 2
			
			-- Sheet entries w/out a title will not open with the first keypress of Return, but a 2nd attempt will
			repeat while row_open_attempts > 0
				tell theTable
					set myRow to row row_index
					select row row_index
					--delay 1
					set focused to true
					-- open the sheet
					keystroke return
					set focused to true
				end tell
				
				try
					set theSheet to sheet 1 of prefsWin
					set row_open_attempts to 0
					if theSheet is not 0 then
						-- Any of the URL, Username or Password values be empty					
						set theURLtable to table 1 of scroll area 1 of theSheet
						set nURLs to the count of rows of theURLtable
						-- say "row " & row_index & "count " & nURLs
						set url_index to 1
						repeat while url_index ² nURLs
							local aURL
							set aURL to (the value of static text of item 1 of UI element 1 of row url_index of theURLtable) as text
							-- say "url row " & url_index
							if url_index is equal to 1 then
								if aURL is missing value or aURL is equal to "" then
									-- say "site missing or empty"
								else
									-- say "site " & theSite
									-- For the Title, just duplicate the URL field
									copy aURL to theSite
									copy aURL to theTitle
								end if
							else
								-- push extra URLs to the notes area
								set the end of urlList to aURL
							end if
							set url_index to url_index + 1
						end repeat
						
						try
							set theUser to value of attribute "AXValue" of text field 1 of theSheet
						end try
						try
							set thePass to value of attribute "AXValue" of text field 2 of theSheet
						end try
						
						--if (count of urlList) is greater than 0 then
						--	set beginning of urlList to "Extra URLs"
						--end if
						
						set theURLs to Join(character id 59, urlList) of me
						local tmpList
						set tmpList to {theTitle, theSite, theUser, thePass, theURLs}
						copy tmpList to rowValues
						set the end of tableEntries to rowValues
						
						-- close the sheet
						keystroke return
					end if
					
				on error
					--say "Sheet for row " & row_index & "did not open - Skipping Entry"
					set failed_rows to failed_rows + 1
					set row_open_attempts to row_open_attempts - 1
				end try
			end repeat
			set row_index to row_index + 1
		end repeat
		
	end tell
	
	return tableEntries
end FetchEntries

on write_csv_file(Entries, fpath)
	local rowdata
	set beginning of Entries to {"Title", "Login URL", "Login Username", "Login Password", "Additional URLs"}
	
	set csvstr to ""
	set i to 1
	repeat while i ² (count of Entries)
		--say "Row " & i
		set rowdata to item i of Entries
		
		if csvstr is not "" then
			set csvstr to csvstr & character id 10
		end if
		
		set j to 1
		repeat while j ² (count of rowdata)
			--say "Column " & j
			set encoded to CSVCellEncode(item j of rowdata)
			if csvstr is "" then
				set csvstr to encoded
			else if j is 1 then
				set csvstr to csvstr & encoded
			else
				set csvstr to csvstr & "," & encoded
			end if
			set j to j + 1
		end repeat
		set i to i + 1
	end repeat
	
	set theResult to WriteTo(fpath, csvstr, Çclass utf8È, false)
	return theResult
end write_csv_file

on WriteTo(targetFile, theData, dataType, append)
	try
		set targetFile to targetFile as text
		set openFile to open for access file targetFile with write permission
		if append is false then set eof of openFile to 0
		write theData to openFile starting at eof as dataType
		close access openFile
		return true
	on error
		try
			close access file targetFile
		end try
		return false
	end try
end WriteTo

on CSVCellEncode(cellstr)
	--say cellstr
	if cellstr is "" then return ""
	set orig to cellstr
	set cellstr to ""
	repeat with c in the characters of orig
		set c to c as text
		if c is "\"" then
			set cellstr to cellstr & "\"\""
		else
			set cellstr to cellstr & c
		end if
	end repeat
	
	if (cellstr contains "," or cellstr contains " " or cellstr contains "\"" or cellstr contains return or cellstr contains character id 10) then set cellstr to quote & cellstr & quote
	
	return cellstr
end CSVCellEncode

on SpeakList(l, name)
	say "List named " & name
	repeat with theItem in l
		say theItem
	end repeat
end SpeakList

on GetTitleFromURL(val)
	copy val to title
	-- applescript's lack of RE's sucks
	set pats to {"http://", "https://"}
	repeat with pat in pats
		set title to my ReplaceText(pat, "", title)
	end repeat
	return item 1 of my Split(title, "/")
end GetTitleFromURL

on ReplaceText(find, replace, subject)
	set prevTIDs to text item delimiters of AppleScript
	set text item delimiters of AppleScript to find
	set subject to text items of subject
	
	set text item delimiters of AppleScript to replace
	set subject to subject as text
	set text item delimiters of AppleScript to prevTIDs
	return subject
end ReplaceText

on Split(theString, theDelimiter)
	set oldDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to theDelimiter
	set theArray to every text item of theString
	set AppleScript's text item delimiters to oldDelimiters
	return theArray
end Split

on Join(delims, l)
	local ret
	set prevTIDs to AppleScript's text item delimiters
	set AppleScript's text item delimiters to delims
	set ret to items of l as text
	set AppleScript's text item delimiters to prevTIDs
	return ret
end Join
