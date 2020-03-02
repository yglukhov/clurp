import strutils

proc quoteShellWindows(s: string): string {.compileTime, used.} =
    ## Quote s, so it can be safely passed to Windows API.
    ## Based on Python's subprocess.list2cmdline
    ## See http://msdn.microsoft.com/en-us/library/17w5ykft.aspx
    let needQuote = {' ', '\t'} in s or s.len == 0

    result = ""
    var backslashBuff = ""
    if needQuote:
      result.add("\"")

    for c in s:
      if c == '\\':
        backslashBuff.add(c)
      elif c == '\"':
        result.add(backslashBuff)
        result.add(backslashBuff)
        backslashBuff.setLen(0)
        result.add("\\\"")
      else:
        if backslashBuff.len != 0:
          result.add(backslashBuff)
          backslashBuff.setLen(0)
        result.add(c)

    if needQuote:
      result.add("\"")

proc quoteShellPosix(s: string): string {.compileTime, used.} =
    ## Quote ``s``, so it can be safely passed to POSIX shell.
    ## Based on Python's pipes.quote
    const safeUnixChars = {'%', '+', '-', '.', '/', '_', ':', '=', '@',
                            '0'..'9', 'A'..'Z', 'a'..'z'}
    if s.len == 0:
        return "''"

    let safe = s.allCharsInSet(safeUnixChars)

    if safe:
        return s
    else:
        return "'" & s.replace("'", "'\"'\"'") & "'"

proc quoteShell*(s: string): string {.compileTime.} =
    ## Quote ``s``, so it can be safely passed to shell.
    when defined(Windows):
        return quoteShellWindows(s)
    elif defined(posix):
        return quoteShellPosix(s)
    else:
        {.error:"quoteShell is not supported on your system".}
