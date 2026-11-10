-- MPC Touch launcher: makes sure the Akai MPC Touch driver setting is active (it is lost after a Mac restart),
-- then starts MPC with the DisplayLink workaround so MPC fully connects to the MPC Touch.
set fixDir to (POSIX path of (path to application support folder from user domain)) & "MPCTouchFix"
set statusTool to quoted form of (fixDir & "/mpctouch-status")
set kextCmd to "kmutil load -p /Library/Extensions/AkaiProfessionalMPCTouch.kext; [ -d /Library/Extensions/AkaiTouchPanel.kext ] && kmutil load -p /Library/Extensions/AkaiTouchPanel.kext; true"

if application "MPC" is running then
	display dialog "MPC is already running. Quit it first (⌘Q), then open MPC Touch again." buttons {"OK"} default button 1
	return
end if

set touchState to do shell script statusTool
if touchState is "absent" then
	display dialog "The MPC Touch isn't connected (or not switched on)." & return & "Connect it, wait for its screen to light up, then click Try Again." buttons {"Open MPC Anyway", "Try Again"} default button 2
	if button returned of result is "Try Again" then set touchState to do shell script statusTool
end if

if touchState is "offline" then
	-- After a restart the Akai settings (MIDI + touch panel) are inactive: load them (asks for the Mac password)
	try
		do shell script kextCmd with administrator privileges
	on error errMsg
		display dialog "Could not load the MPC Touch driver setting:" & return & errMsg buttons {"OK"} default button 1 with icon caution
	end try
	repeat 10 times
		delay 1
		set touchState to do shell script statusTool
		if touchState is "online" then exit repeat
	end repeat
	if touchState is not "online" then display dialog "The MPC Touch is still not reachable over MIDI." & return & "Unplug its USB cable, plug it back in, then click OK." buttons {"OK"} default button 1
end if

-- Start MPC's binary directly: "open -a --env" goes through LaunchServices, which drops DYLD_INSERT_LIBRARIES on this Mac
do shell script "nohup env DYLD_INSERT_LIBRARIES=" & quoted form of (fixDir & "/fakedl.dylib") & " /Applications/MPC.app/Contents/MacOS/MPC > /dev/null 2>&1 &"
