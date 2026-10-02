BeginTextToolRun(batch, text) {
    global TextToolRuns, TextToolRoot
    Critical "On"
    run := 0
    BeginTextToolPaint(batch)
    try {
        if batch.Current
            StopTextToolRun(batch.Current)
        batch.Current := 0
        batch.Scroll := 0
        ResetTextToolResults(batch)
        run := CreateTextToolRun(batch, text)
        StartTextToolRunTasks(run)
        SetTimer(run.Poller, 200)
    } catch as err {
        if run {
            StopTextToolRun(run)
            SetTimer(run.Poller, 200)
        }
        for row in batch.Tasks {
            row.Status.Value := "Failed to start"
            row.Error := err.Message
            SetRichText(row.ErrorEdit, err.Message, batch.Ui.LineHeight)
        }
    } finally {
        try LayoutTextTools(batch, 0, 0)
        finally {
            EndTextToolPaint(batch)
            Critical "Off"
        }
    }
}

CreateTextToolRun(batch, text) {
    global TextToolRuns
    guid := Buffer(16)
    DllCall("ole32\CoCreateGuid", "ptr", guid)
    guidText := Buffer(78)
    DllCall("ole32\StringFromGUID2", "ptr", guid, "ptr", guidText, "int", 39)
    directory := A_Temp "\text-tools-" StrGet(guidText)
    run := {Dir: directory, Tasks: [], Process: 0, Owner: batch, Cancelled: false, Cleaned: false, Poller: 0}
    run.Poller := (*) => PollTextToolBatch(run)
    TextToolRuns[directory] := run
    batch.Current := run
    DirCreate(directory)
    run.Input := directory "\input.txt"
    FileAppend(text, run.Input, "UTF-8-RAW")
    run.ErrorFile := directory "\batch.err"
    return run
}

; One process runs every engine; each reports through its own N.status file.
; A start failure throws to BeginTextToolRun before any task exists to poll.
StartTextToolRunTasks(run) {
    global TextToolRoot
    batch := run.Owner
    engines := ""
    for row in batch.Tasks
        engines .= row.Engine "`n"
    engineFile := run.Dir "\engines.txt"
    FileAppend(engines, engineFile, "UTF-8-RAW")
    run.Process := ChildProcess(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        TextToolRoot "\ahk\run-batch.ps1", "-Tool", batch.Tool, "-InputFile", run.Input,
        "-EngineFile", engineFile, "-OutputDirectory", run.Dir], run.ErrorFile)
    for row in batch.Tasks {
        run.Tasks.Push({Row: row, Done: false, StatusFile: run.Dir "\" A_Index ".status",
            OutputFile: run.Dir "\" A_Index ".out", ErrorFile: run.Dir "\" A_Index ".err"})
        row.Status.Value := "Running..."
    }
}

StopTextToolRun(run) {
    run.Cancelled := true
    if run.Process
        run.Process.Stop()
}

PollTextToolBatch(run) {
    ; Prevent a submit/close interrupt between the ownership check and a UI write.
    Critical "On"
    try {
        if run.Cleaned
            return
        batch := run.Owner
        active := batch.Open && batch.Current = run && !run.Cancelled
        ; Before the status files: once the process has exited, every status
        ; file it was going to write already exists.
        exited := !run.Process || run.Process.Poll()
        allDone := exited
        updates := []
        for task in run.Tasks {
            if task.Done
                continue
            errorFile := task.ErrorFile
            exitCode := GetTextToolTaskExit(task, run, exited, &errorFile)
            finished := exitCode != ""
            if active {
                row := task.Row
                output := row.Output, errorOutput := row.Error
                outputRead := TryReadTaskFile(task.OutputFile, &output)
                errorRead := TryReadTaskFile(errorFile, &errorOutput)
                ; A final locked file must be retried before disposing the task.
                if finished && ((!outputRead && FileExist(task.OutputFile)) || (!errorRead && FileExist(errorFile)))
                    finished := false
                status := finished ? (exitCode != 0 ? "Failed (exit " exitCode ")" : (Trim(output) = "" ? "Failed (empty output)" : "Completed")) : row.Status.Value
                if !(output == row.Output) || !(errorOutput == row.Error) || !(status == row.Status.Value)
                    updates.Push({Row: row, Output: output, Error: errorOutput, Status: status})
            }
            if finished
                task.Done := true
            else
                allDone := false
        }
        if updates.Length && active {
            BeginTextToolPaint(batch)
            try {
                layoutChanged := false
                for update in updates {
                    row := update.Row
                    if !(update.Output == row.Output) {
                        UpdateRichText(row.Edit, row.Output, update.Output, batch.Ui.LineHeight)
                        batch.DirtyWindows[row.Edit] := 1
                        layoutChanged := true
                    }
                    if !(update.Error == row.Error) {
                        UpdateRichText(row.ErrorEdit, row.Error, update.Error, batch.Ui.LineHeight)
                        batch.DirtyWindows[row.ErrorEdit] := 1
                        layoutChanged := true
                    }
                    row.Output := update.Output, row.Error := update.Error
                    if !(row.Status.Value == update.Status) {
                        row.Status.Value := update.Status
                        batch.DirtyWindows[row.Status.Hwnd] := 5
                    }
                }
                if layoutChanged
                    LayoutTextTools(batch, 0, 0)
            } finally {
                EndTextToolPaint(batch)
            }
        }
        if allDone {
            SetTimer(run.Poller, 0)
            ; Cleared so a cleanup retry never polls a disposed process.
            if run.Process {
                run.Process.Dispose()
                run.Process := 0
            }
            CleanupTextToolRun(run)
        }
    } finally {
        Critical "Off"
    }
}

; Exit code of a finished task, or "" while it still runs.
GetTextToolTaskExit(task, run, exited, &errorFile) {
    if TryReadTaskFile(task.StatusFile, &statusText)
        return Trim(statusText)
    ; A locked status file is retried. A missing one after exit means the batch
    ; stopped before this engine finished, and only its own error says why.
    if !exited || FileExist(task.StatusFile)
        return ""
    errorFile := run.ErrorFile
    return run.Process.ExitCode || 1
}

CleanupTextToolRun(run) {
    global TextToolRuns
    ; Called only after all job members exit. Check the absolute target before deletion.
    resolved := Buffer(65536)
    DllCall("GetFullPathNameW", "str", run.Dir, "uint", 32768, "ptr", resolved, "ptr", 0)
    target := StrGet(resolved)
    if !RegExMatch(target, "i)^" RegExReplace(A_Temp, "[\\.^$|?*+()\[\]{}]", "\$0") "\\text-tools-\{[0-9a-f-]{36}\}$")
        throw Error("Unrecognized text tools batch directory")
    try {
        if DirExist(target)
            DirDelete(target, true)
        run.Cleaned := true
        if TextToolRuns.Has(run.Dir)
            TextToolRuns.Delete(run.Dir)
        ; Release the timer closure and owner link after the final cleanup.
        run.Poller := 0
        run.Owner := 0
    } catch {
        ; Retry transient antivirus/file-sharing locks without losing ownership.
        if run.Poller
            SetTimer(run.Poller, 200)
    }
}

TryReadTaskFile(path, &text) {
    try {
        text := FileRead(path, "UTF-8")
        return true
    } catch {
        return false
    }
}
