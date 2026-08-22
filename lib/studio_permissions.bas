' studio_permissions — STU-10 the agent permission model (headless).
'
' STU-6 made the agent read-only STRUCTURALLY: there was no write tool to permit
' or forbid, so there was nothing to get wrong. STU-10 ends that deliberately, and
' the safety property has to be replaced rather than dropped. This is the
' replacement.
'
' THREE TIERS (§17), and the line between them is REVERSIBILITY, not danger:
'
'   read      observe project, files, state, variables, history. Nothing changes.
'   local     navigate, create a branch, edit code, run a section. Everything
'             here is undoable inside Studio — a buffer edit is unsaved until
'             Save, a branch is discardable, a run leaves a result you can ignore.
'   external  delete a file, save over a changed file, push, write outside the
'             workspace. These are the §8.3 non-rewindable set: once done, Studio
'             cannot put them back.
'
' THREE POLICIES: auto | confirm | deny. Strictness orders them, and that order is
' the whole of how scopes compose.
'
' SCOPES NARROW, THEY DO NOT WIDEN (§16 precedence, read as a safety rule).
' Global sets a default, project may narrow it, session may clamp everything down
' — "read-only this investigation". The effective policy is therefore the MOST
' RESTRICTIVE across the three, not the innermost one. That asymmetry is
' deliberate: if the innermost scope simply won, a project config could quietly
' hand the agent more authority than the user granted globally, and the file
' granting it would be one checked into the repository someone else wrote.
'
' CONFIRMATION IS BOUND TO THE ACT, NOT TO A FLAG. A confirmation names the exact
' tool and arguments it authorizes, hashed into a token. Confirming "delete a.bas"
' cannot authorize "delete b.bas" — the same rule Delete and Close already follow
' in the window, where an arm is keyed to the path or the document id rather than
' to a boolean.
library studio_permissions


    function schema_version()
        return 1
    end function

    function tiers()
        return ["read", "local", "external"]
    end function

    function policies()
        return ["auto", "confirm", "deny"]
    end function

    function is_tier(t)
        return contains(studio_permissions.tiers(), t)
    end function

    function is_policy(p)
        return contains(studio_permissions.policies(), p)
    end function

    ' How restrictive a policy is. Higher wins when scopes disagree.
    function _rank(p)
        if p = "auto" then
            return 0
        end if
        if p = "confirm" then
            return 1
        end if
        if p = "deny" then
            return 2
        end if
        ' An unreadable policy is treated as the strictest one there is. A config
        ' file with a typo in it must not be a config file that grants more.
        return 2
    end function

    ' The shipped defaults.
    '
    ' `local` defaults to CONFIRM, not auto. An agent that edits your code the
    ' first time you talk to it is a bad surprise even when every edit is
    ' reversible, and the design calls this tier "configurable autonomy" — which
    ' means the user turns it up, not that it arrives turned up.
    function defaults()
        return { read: "auto", local: "confirm", external: "confirm" }
    end function

    ' A policy set with ONLY the tiers a scope actually spoke about. An absent
    ' tier is an absent OPINION, not a default one.
    '
    ' This distinction was a real bug before it was a comment. Falling back to
    ' `defaults()` for an unset scope meant an unset PROJECT narrowed a global
    ' `local: auto` back to `confirm` — every scope silently voting the shipped
    ' default, so the user's own global setting could never take effect at all.
    function stated(raw)
        out = {}
        if raw = nothing then
            return out
        end if
        if not is_record(raw) then
            return out
        end if
        for each t in studio_permissions.tiers()
            v = raw[t]
            if v != unknown then
                if is_string(v) then
                    if studio_permissions.is_policy(v) then
                        out[t] = v
                    end if
                end if
            end if
        end for
        return out
    end function

    ' A complete policy set: the shipped defaults with a scope's statements laid
    ' over them. Used for the GLOBAL scope, which is the base — it is the user's
    ' own setting and may widen as well as narrow.
    function normalize(raw)
        out = studio_permissions.defaults()
        for each t in studio_permissions.tiers()
            v = studio_permissions.stated(raw)[t]
            if v != unknown then
                out[t] = v
            end if
        end for
        return out
    end function

    ' The three scopes composed.
    '
    '   global   the base: defaults, overridden by whatever the user set.
    '   project  may only NARROW it.
    '   session  may only narrow it further.
    '
    ' The asymmetry is deliberate. If the innermost scope simply won, a project
    ' config could quietly hand the agent more authority than the user granted
    ' globally — and the file granting it would be one checked into a repository
    ' somebody else wrote.
    function effective(global_raw, project_raw, session_raw)
        base = studio_permissions.normalize(global_raw)
        p = studio_permissions.stated(project_raw)
        s = studio_permissions.stated(session_raw)
        out = {}
        for each t in studio_permissions.tiers()
            v = base[t]
            if p[t] != unknown then
                v = studio_permissions._strictest(v, p[t])
            end if
            if s[t] != unknown then
                v = studio_permissions._strictest(v, s[t])
            end if
            out[t] = v
        end for
        return out
    end function

    function _strictest(a, b)
        if studio_permissions._rank(a) >= studio_permissions._rank(b) then
            return a
        end if
        return b
    end function

    function policy_for(effective_set, tier)
        if not studio_permissions.is_tier(tier) then
            ' A tool declaring a tier that does not exist is a bug in the
            ' registry, and the safe reading of a bug is the strictest one.
            return "deny"
        end if
        v = effective_set[tier]
        if v = unknown then
            return "deny"
        end if
        return v
    end function

    ' ---- confirmation tokens ------------------------------------------------

    ' A token naming exactly one act. Built from the tool name and its arguments,
    ' so a confirmation cannot be spent on anything else — the property the
    ' window's two-click Delete already has, expressed for a caller that is not a
    ' pair of clicks.
    '
    ' `encode` gives a canonical, order-stable rendering of a record, so the same
    ' call always hashes the same way and a different one does not.
    function token(name, args)
        return name + ":" + studio_permissions._hash(name + "|" + encode(args))
    end function

    ' A rolling hash, pure gBASIC. Not cryptographic and not required to be: this
    ' is a same-process handshake between a caller and a dispatcher, not a
    ' credential. What it must do is differ when the act differs, which it does.
    function _hash(text)
        m = 1000000007
        h = 0
        i = 0
        n = byte_count(text)
        while i < n
            h = studio_permissions._modulo(h * 131 + byte_at(text, i), m)
            i = i + 1
        end while
        return string(h)
    end function

    ' Named `_modulo`, not `_mod`: studio_sections already has a `_mod`, and gBASIC
    ' warns that one library's function overrides another's of the same name. Two
    ' private helpers with one name is a warning today and whichever one loaded
    ' last tomorrow.
    function _modulo(a, b)
        return a - floor(a / b) * b
    end function

    ' The policy a value MEANS, which for anything unrecognised is "deny".
    function _canonical(p)
        r = studio_permissions._rank(p)
        if r = 0 then
            return "auto"
        end if
        if r = 1 then
            return "confirm"
        end if
        return "deny"
    end function

    ' What a caller must do before this act may run:
    '   allowed        go ahead
    '   needs-confirm  come back with `token`
    '   denied         not this session, whatever the caller does
    function decide(effective_set, tier, name, args, confirmed)
        ' Read through the RANK, not through string equality on the stored value.
        ' `_rank` already says an unreadable policy is the strictest thing there
        ' is; comparing the raw string against "deny" and "auto" made an
        ' unrecognised value fall through to `confirm` instead — so `_rank` and
        ' `decide` disagreed about the same typo, and the more permissive one won.
        ' `effective()` filters these out, but `policy_for` is public and a
        ' hand-built policy set reaches here directly.
        p = studio_permissions._canonical(studio_permissions.policy_for(effective_set, tier))
        if p = "deny" then
            return { verdict: "denied", token: "",
                     why: "the " + tier + " tier is denied by policy" }
        end if
        if p = "auto" then
            return { verdict: "allowed", token: "", why: "" }
        end if
        want = studio_permissions.token(name, args)
        if confirmed = want then
            return { verdict: "allowed", token: want, why: "" }
        end if
        return { verdict: "needs-confirm", token: want,
                 why: name + " is " + studio_permissions._article(tier) + " " + tier + " action and needs confirmation" }
    end function

    function _article(tier)
        if tier = "external" then
            return "an"
        end if
        return "a"
    end function

    ' ---- summaries ----------------------------------------------------------

    function summary(effective_set)
        out = []
        for each t in studio_permissions.tiers()
            out = append(out, "  " + t + ": " + studio_permissions.policy_for(effective_set, t))
        end for
        return out
    end function

    ' A one-line description of where a policy came from, for the window and for
    ' anyone asking why the agent refused. Naming the scope matters: "denied" with
    ' no reason is indistinguishable from a broken agent.
    '
    ' The winner is the OUTERMOST scope that set the effective value, because a
    ' narrowing is attributable to the first scope that imposed it — a session
    ' that repeats what the project already said did not cause anything.
    function why_line(global_raw, project_raw, session_raw, tier)
        eff = studio_permissions.effective(global_raw, project_raw, session_raw)
        v = studio_permissions.policy_for(eff, tier)
        base = studio_permissions.normalize(global_raw)
        if base[tier] = v then
            if studio_permissions.stated(global_raw)[tier] = unknown then
                return tier + " = " + v + " (default)"
            end if
            return tier + " = " + v + " (from global)"
        end if
        if studio_permissions.stated(project_raw)[tier] = v then
            return tier + " = " + v + " (narrowed by project)"
        end if
        return tier + " = " + v + " (narrowed by session)"
    end function

end library
