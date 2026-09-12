; Each suspended process joins a kill-on-close job before any script can run.
; Native handles provide exit status and avoid PID reuse during cancellation.
class Proc {
    __New(arguments, errorFile) {
        this.Handle := 0
        this.Job := 0
        this.ExitCode := ""
        this.Stopping := false
        this.Job := DllCall("CreateJobObjectW", "ptr", 0, "ptr", 0, "ptr")
        if !this.Job
            throw OSError()
        limits := Buffer(A_PtrSize = 8 ? 144 : 112, 0)
        NumPut("uint", 0x2000, limits, 16) ; JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if !DllCall("SetInformationJobObject", "ptr", this.Job, "int", 9, "ptr", limits, "uint", limits.Size) {
            this.Dispose()
            throw OSError()
        }
        security := Buffer(A_PtrSize = 8 ? 24 : 12, 0)
        NumPut("uint", security.Size, security)
        NumPut("int", 1, security, A_PtrSize = 8 ? 16 : 8)
        handles := []
        threadHandle := 0
        try {
            for spec in [[errorFile, 0x40000000, 2], ["NUL", 0x40000000, 3], ["NUL", 0x80000000, 3]] {
                handle := DllCall("CreateFileW", "str", spec[1], "uint", spec[2], "uint", 3, "ptr", security, "uint", spec[3], "uint", 0x80, "ptr", 0, "ptr")
                if handle = -1
                    throw OSError()
                handles.Push(handle)
            }
            startup := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
            NumPut("uint", startup.Size, startup)
            NumPut("uint", 0x100, startup, A_PtrSize = 8 ? 60 : 44)
            NumPut("ptr", handles[3], "ptr", handles[2], "ptr", handles[1], startup, A_PtrSize = 8 ? 80 : 56)
            processInfo := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
            executable := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
            command := QuoteWindows(executable)
            for argument in arguments
                command .= " " QuoteWindows(argument)
            commandBuffer := Buffer((StrLen(command) + 1) * 2)
            StrPut(command, commandBuffer, "UTF-16")
            if !DllCall("CreateProcessW", "str", executable, "ptr", commandBuffer, "ptr", 0, "ptr", 0, "int", true, "uint", 0x08000004, "ptr", 0, "ptr", 0, "ptr", startup, "ptr", processInfo)
                throw OSError()
            this.Handle := NumGet(processInfo, 0, "ptr")
            threadHandle := NumGet(processInfo, A_PtrSize, "ptr")
            this.Pid := NumGet(processInfo, A_PtrSize * 2, "uint")
            if !DllCall("AssignProcessToJobObject", "ptr", this.Job, "ptr", this.Handle)
                throw OSError()
            if DllCall("ResumeThread", "ptr", threadHandle, "uint") = 0xFFFFFFFF
                throw OSError()
        } catch as err {
            if this.Handle {
                DllCall("TerminateProcess", "ptr", this.Handle, "uint", 1)
                DllCall("WaitForSingleObject", "ptr", this.Handle, "uint", 5000)
            }
            this.Dispose()
            throw err
        } finally {
            if threadHandle
                DllCall("CloseHandle", "ptr", threadHandle)
            for handle in handles
                DllCall("CloseHandle", "ptr", handle)
        }
    }
    Stop() {
        if this.Job && !this.Stopping {
            if !DllCall("TerminateJobObject", "ptr", this.Job, "uint", 130)
                throw OSError()
            this.Stopping := true
        }
    }
    Poll() {
        if DllCall("WaitForSingleObject", "ptr", this.Handle, "uint", 0) != 0
            return false
        code := 0
        if !DllCall("GetExitCodeProcess", "ptr", this.Handle, "uint*", &code)
            throw OSError()
        this.ExitCode := code
        this.Stop() ; Also reap descendants left by a failed parent.
        accounting := Buffer(48, 0)
        if !DllCall("QueryInformationJobObject", "ptr", this.Job, "int", 1, "ptr", accounting, "uint", 48, "ptr", 0)
            throw OSError()
        return NumGet(accounting, 40, "uint") = 0
    }
    Dispose() {
        if this.Job
            DllCall("CloseHandle", "ptr", this.Job)
        if this.Handle
            DllCall("CloseHandle", "ptr", this.Handle)
        this.Job := 0
        this.Handle := 0
    }
}

QuoteWindows(value) {
    return Chr(34) RegExReplace(RegExReplace(value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') Chr(34)
}
