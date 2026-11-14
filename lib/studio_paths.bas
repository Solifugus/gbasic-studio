' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_paths — a path from the operating system, in the one form Studio
' speaks inside (headless).
'
' gBASIC's rule, from its Windows port (`docs/windows_port_status.md` §29):
' gBASIC SPEAKS `/`, and the platform layer normalises at the boundary.
' Windows accepts `/` everywhere a path is handed back to it, while on POSIX a
' backslash is an ordinary filename character and must not be touched. So
' Studio does the same: a path that arrives from OUTSIDE -- a command-line
' argument, an environment variable, a typed folder -- goes through
' `from_os` once, and everything after that may assume `/`.
'
' Found by the first Windows run (`docs/windows_findings.md`, item 5): a home
' of `C:\gbt\sc\h5` was read as RELATIVE, because the only absolute test was
' a leading `/`, and Open Samples looked for its copy under the launch
' directory. The platform is a PARAMETER of each `_on` function, so Linux can
' assert the Windows answers.

library studio_paths

    ' Which platform this gBASIC was built for: "windows", "linux", "macos"
    ' or "posix". `platform()` is in 0.10.0; a build without it is POSIX.
    function os_name()
        if has_builtin("platform") then
            return platform()
        end if
        return "posix"
    end function

    function from_os(p)
        return studio_paths.from_os_on(p, studio_paths.os_name())
    end function

    ' On Windows, every `\` becomes `/`. Anywhere else the path is unchanged,
    ' because there a backslash is part of a name.
    function from_os_on(p, os)
        if not is_string(p) then
            return p
        end if
        if os != "windows" then
            return p
        end if
        return replace(p, "\\", "/")
    end function

    function is_absolute(p)
        return studio_paths.is_absolute_on(p, studio_paths.os_name())
    end function

    ' `/x` everywhere; on Windows also a drive (`C:/x`, `C:\x`) and a share
    ' (`//server/x`, `\\server\x`). `C:x` -- a drive with no separator -- is
    ' relative to that drive's current directory, so it is NOT absolute.
    function is_absolute_on(p, os)
        q = studio_paths.from_os_on(p, os)
        if starts_with(q, "/") then
            return true
        end if
        if os = "windows" then
            return studio_paths.drive_of(q) != ""
        end if
        return false
    end function

    ' The drive a Windows path starts with, `C:` (as written), or "".
    ' Only `X:/`: a letter, a colon, and a separator, after `from_os`.
    function drive_of(q)
        if len(q) < 3 then
            return ""
        end if
        if mid(q, 1, 1) != ":" or mid(q, 2, 1) != "/" then
            return ""
        end if
        c = lower(mid(q, 0, 1))
        if not contains("abcdefghijklmnopqrstuvwxyz", c) then
            return ""
        end if
        return left(q, 2)
    end function

end library
