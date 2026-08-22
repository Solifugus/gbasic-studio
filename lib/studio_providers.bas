' studio_providers — STU-10 selectable LLM providers (headless). §15.
'
' Studio does not implement a provider. `llm.bas` already adapts three wire
' formats and this chooses between them, resolves the credential, and reports
' precisely why it cannot when it cannot.
'
' WHERE A CREDENTIAL COMES FROM, in order, and the order is the point:
'
'   1. the SECRET STORE (studio_secrets). Encrypted, and the only place Studio
'      itself will ever put one.
'   2. the provider's environment variable. Not stored by Studio, but the
'      convention every other tool uses, and refusing to read it would mean
'      telling a user their working setup is unsupported.
'
' Which one answered is REPORTED, never inferred. "It works on my machine and
' not on yours" is usually this question, and a settings pane that cannot say
' where the key came from cannot answer it.
'
' A LOCAL provider needs no credential at all. That is not a lesser case to be
' handled at the end — for anyone who cannot send their source to a third party
' it is the only case, so it is in the registry beside the others.
library studio_providers


    load llm
    load studio_secrets

    function schema_version()
        return 1
    end function

    ' The providers a user may pick. `secret` is the name a key is stored under;
    ' `env` is the variable checked second.
    function registry()
        out = []
        out = append(out, { id: "anthropic", label: "Anthropic",
                            needs_key: true, secret: "anthropic", env: "ANTHROPIC_API_KEY",
                            model: "claude-sonnet-4-20250514",
                            note: "Claude, over the Anthropic API." })
        out = append(out, { id: "openai", label: "OpenAI",
                            needs_key: true, secret: "openai", env: "OPENAI_API_KEY",
                            model: "gpt-4o",
                            note: "GPT, over the OpenAI API." })
        out = append(out, { id: "local", label: "Local model",
                            needs_key: false, secret: "", env: "",
                            model: "llama3.1",
                            note: "Ollama or vLLM on this machine, in the OpenAI wire format. Nothing leaves the machine." })
        return out
    end function

    function ids()
        out = []
        for each p in studio_providers.registry()
            out = append(out, p.id)
        end for
        return out
    end function

    function by_id(id)
        for each p in studio_providers.registry()
            if p.id = id then
                return p
            end if
        end for
        return nothing
    end function

    function default_id()
        return "anthropic"
    end function

    ' Where a local model is expected to be. Overridable, because the whole point
    ' of the local provider is that it is the user's own.
    function local_url()
        v = env("GBASIC_STUDIO_LOCAL_URL")
        if is_string(v) then
            if v != "" then
                return v
            end if
        end if
        return "http://localhost:11434"
    end function

    ' ---- credentials --------------------------------------------------------

    ' The key for a provider, and WHERE it came from.
    '   source: "store" | "env" | "none" | "not-needed"
    function credential(home, secret_key, id)
        p = studio_providers.by_id(id)
        if p = nothing then
            return { ok: false, key: "", source: "none", why: "no provider named " + quote(id) }
        end if
        if not p.needs_key then
            return { ok: true, key: "", source: "not-needed", why: "" }
        end if
        g = studio_secrets.get(home, secret_key, p.secret)
        if g.ok then
            return { ok: true, key: g.value, source: "store", why: "" }
        end if
        v = env(p.env)
        if is_string(v) then
            if v != "" then
                return { ok: true, key: v, source: "env", why: "" }
            end if
        end if
        return { ok: false, key: "", source: "none",
                 why: p.label + " has no key: store one as " + quote(p.secret) + " or set " + p.env }
    end function

    ' Build the handle, or say why not. A missing key is a VALUE, never a raise:
    ' the window has to keep working for someone who has not configured an
    ' assistant, which is most people most of the time.
    function resolve(home, secret_key, id, model)
        p = studio_providers.by_id(id)
        if p = nothing then
            return { ok: false, handle: nothing, source: "none",
                     why: "no provider named " + quote(id) + "; there is " + join(studio_providers.ids(), ", ") }
        end if
        use_model = p.model
        if is_string(model) then
            if model != "" then
                use_model = model
            end if
        end if
        c = studio_providers.credential(home, secret_key, id)
        if not c.ok then
            return { ok: false, handle: nothing, source: c.source, why: c.why }
        end if
        if id = "local" then
            return { ok: true, handle: llm.local(studio_providers.local_url(), use_model),
                     source: c.source, why: "" }
        end if
        if id = "anthropic" then
            return { ok: true, handle: llm.anthropic(use_model, c.key), source: c.source, why: "" }
        end if
        return { ok: true, handle: llm.openai(use_model, c.key), source: c.source, why: "" }
    end function

    ' What a settings pane shows. Never the key — whether there is one.
    function summary(home, secret_key)
        out = []
        for each p in studio_providers.registry()
            c = studio_providers.credential(home, secret_key, p.id)
            state = "no key"
            if c.source = "store" then
                state = "key from the secret store"
            end if
            if c.source = "env" then
                state = "key from " + p.env
            end if
            if c.source = "not-needed" then
                state = "needs no key"
            end if
            out = append(out, "  " + p.id + " (" + p.label + ") — " + state)
            out = append(out, "      model: " + p.model)
        end for
        return out
    end function

end library
