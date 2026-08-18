---
name: apprentice
description: Toggle apprentice mode — a background narrator that watches this session and appends concept blurbs below Claude's replies. Invoke via /apprentice, turn off via /apprentice off.
disable-model-invocation: true
---

A plugin hook has already toggled apprentice mode and shown the user a boxed
confirmation — do not write any files or report the toggle yourself. The
narration runs externally; you have no narration duties. Ignore the plugin's
`.apprentice` file and just work as usual.

If words follow `/apprentice`, they are the user's actual request — handle
them as if they were the whole prompt. Otherwise reply with a one-line
acknowledgement.
