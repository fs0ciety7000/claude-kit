#!/usr/bin/env bash
# PreToolUse hook of Claude Code: blocks real access to secret files and values, and agent writes to kit-managed
# settings and code. It judges the FILES a command touches, never the words it mentions: a jq path such as
# `.environment`, a grep pattern, a commit message, a PR body or a JSON rule that names an env file or a certificate is
# not an access.
#
# Input: JSON on stdin. Output: exit 2 + message on stderr = action blocked.
# Budget: one hook process per tool call (hooks_per_tool_call.* = 1): one jq and one awk (plus a readlink when the hook
# is a symlink), except `git diff` when the command commits.
# Fails closed: if the analysis cannot run (awk missing or failing, input over 256 KB) the action is blocked.
#
# Blocked:
#   - Read/Edit/Write/MultiEdit/NotebookEdit/Grep on a secret file: env files (not the .example/.sample/.template
#     variants), private keys (id_* without .pub, *.pem, *.key...), ~/.ssh private material, token stores (~/.config/gh,
#     ~/.docker, ~/.aws, .netrc, .npmrc, ~/.claude.json...), tofu/terraform state and variable files,
#     /proc/*/environ and /proc/*/task/*/environ.
#   - Bash: the same files as OPERANDS of a reader (cat, head, cp, base64, git add, curl -d @file...) or as the target
#     of a redirection; sops/age decryption, `kit secrets edit`, `gh auth token`, `ssh-keygen -y`; dumps of the
#     environment (printenv, env, set, export -p, declare -p NAME, jq env, os.environ dumps); echo/printf/here-strings of
#     a variable named like a secret unless piped into a known consumer (--password-stdin...); inside `kit secrets run`
#     anything that can print the environment (printenv, echo $X, xtrace, curl -v, os.environ[...], here-strings);
#     `tofu|terraform apply|destroy` under any wrapper or path, `tofu show -json`, `tofu output -json|-raw`, `tofu state
#     pull|show`; `docker compose config` (prints interpolated secrets) except --services/--volumes/--images/--profiles/-q;
#     `docker compose up|build|run` on a compose file with privileged: true, pid/network host, a mount of / or $HOME or
#     the docker socket, or a build context of / or $HOME; recursive grep/rg/Grep from $HOME or / (above credential
#     stores) without a restrictive glob or type; a commit whose diff (in the `git -C` or `cd` directory) contains a key
#     or token pattern.
#   - Writes by an agent (Edit/Write tools; cp, mv, install, rsync, tee, rm, touch, ln, dd, patch, sed -i or sed w, awk
#     redirections, sort -o, uniq OUT, find -fprint/-delete, git --output, curl -o, tar -x, unzip -d, redirections
#     including >|) on ~/.config/claude-kit/**, ~/.claude/settings.json (and settings.local.json) and, for the INSTALLED
#     kit (the real path of this hook), $KIT_HOME/scripts/** and $KIT_HOME/global/settings*.json: only `kit sync`,
#     `kit overlay` and `kit autoupdate` write the first two, and the kit's code is changed in a separate clone.
# It does not block: a command that only names such a file in quoted text, a pattern or a filter; `cp .env.example
# .env` (the destination of a copy is not read); `ls`, `test -f`, `rm` and `chmod` on a secret (metadata only);
# `docker compose --env-file .env up`, `node --env-file=.env`, `openssl x509 -in cert.pem`.
#
# It is defense in depth, not a sandbox: a shell can always hide a path (variable, encoding, interpreter, symlink or
# hard link made earlier). Known limits are listed in README.md (section "Garde-fous et leurs limites"). The real
# protection stays: no plaintext secret on disk, tokens with minimal scope.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0 # without jq nothing is blocked (kit doctor reports it)

# One jq call. Each field is prefixed by "x" so an empty value keeps its line; the command (last) may span lines.
parsed=$(jq -r '
  def one: tostring | gsub("[\r\n]"; " ");
  "x" + (.tool_name // "" | one),
  "x" + (.cwd // "" | one),
  "x" + (.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // "" | one),
  "x" + (.tool_input.glob // "" | one),
  "x" + (.tool_input.type // "" | one),
  "x" + (.tool_input.command // "")' 2>/dev/null) || exit 0

tool=${parsed%%$'\n'*}; parsed=${parsed#*$'\n'}; tool=${tool#x}
cwd=${parsed%%$'\n'*}; parsed=${parsed#*$'\n'}; cwd=${cwd#x}
path=${parsed%%$'\n'*}; parsed=${parsed#*$'\n'}; path=${path#x}
glob=${parsed%%$'\n'*}; parsed=${parsed#*$'\n'}; glob=${glob#x}
gtype=${parsed%%$'\n'*}; cmd=${parsed#*$'\n'}; gtype=${gtype#x}; cmd=${cmd#x}

block() { # kind reason
  {
    echo "Bloqué par claude-kit : $2"
    if [[ $1 == config ]]; then
      echo "Ces réglages et ce code sont écrits par kit seulement : kit sync, kit overlay, kit autoupdate (ou à la main par l'utilisateur, dans un autre clone pour le code du kit)."
    elif [[ $1 == system ]]; then
      echo "Le garde-fou ne peut pas analyser cette action : il refuse par prudence."
    else
      echo "Pour qu'une commande reçoive des secrets sans que tu les voies : kit secrets run -- <commande>"
    fi
  } >&2
  exit 2
}

# The awk program (portable: POSIX awk, no gawk extension; read -d '' needs no fork).
read -r -d '' AWK_PROG <<'AWK_END'
function inl(list, w) { return index(" " list " ", " " w " ") > 0 }
function bn(p,   n, a) { sub(/\/+$/, "", p); n = split(p, a, "/"); return a[n] }
function block(kind, reason) {
  if (blocked) return
  blocked = 1; bkind = kind
  gsub(/[\001-\037\177]/, "?", reason)
  breason = substr(reason, 1, 140)
}

# --- paths ---------------------------------------------------------------------------------------------------
function lead(p, name, val,   l) {
  # $NAME or ${NAME} at the start of p, followed by "/" or the end: replaced by val.
  l = length(name) + 1
  if (substr(p, 1, l) == "$" name && (length(p) == l || substr(p, l + 1, 1) == "/")) return val substr(p, l + 1)
  l = length(name) + 3
  if (substr(p, 1, l) == "${" name "}" && (length(p) == l || substr(p, l + 1, 1) == "/")) return val substr(p, l + 1)
  return p
}
function norm(p,   n, a, i, k, seg, r) {
  if (p == "~") p = HOME
  else if (substr(p, 1, 2) == "~/") p = HOME substr(p, 2)
  p = lead(p, "HOME", HOME)
  p = lead(p, "KIT_CONFIG", KC)
  p = lead(p, "KIT_HOME", KH)
  p = lead(p, "CLAUDE_HOME", CH)
  p = lead(p, "XDG_CONFIG_HOME", XD)
  if (substr(p, 1, 1) != "/" && substr(p, 1, 1) != "$") p = CUR "/" p
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    seg = a[i]
    if (seg == "" || seg == ".") continue
    if (seg == "..") { if (k > 0) k--; continue }
    k++; st[k] = seg
  }
  r = ""
  for (i = 1; i <= k; i++) r = r "/" st[i]
  return (r == "" ? "/" : r)
}
# Shell glob -> anchored ERE (bracket expressions are kept, so .[e]nv matches the env file name).
function glob2re(g,   i, c, r, j, cl) {
  r = "^"
  for (i = 1; i <= length(g); i++) {
    c = substr(g, i, 1)
    if (c == "*") r = r ".*"
    else if (c == "?") r = r "."
    else if (c == "[") {
      j = index(substr(g, i + 2), "]")
      if (j > 0) {
        cl = substr(g, i + 1, j + 0)
        if (substr(cl, 1, 1) == "!") cl = "^" substr(cl, 2)
        r = r "[" cl "]"
        i = i + j + 1
      } else r = r "\\["
    }
    else if (index("\\.+(){}|^$]", c) > 0) r = r "\\" c
    else r = r c
  }
  return r "$"
}
# Can this glob (basename) match a secret file name? Shell semantics: a leading dot must be literal, unless DOTOK
# (ripgrep, find and the Grep tool match dotfiles with *env).
function glob_secret(b,   lit, re, k, s) {
  lit = b; gsub(/[]*?[]/, "", lit)
  if (length(lit) < 2) return 0
  re = glob2re(b)
  for (k = 1; k <= nsamp; k++) {
    s = samp[k]
    if (!DOTOK && substr(s, 1, 1) == "." && substr(b, 1, 1) != ".") continue
    if (s ~ re) return 1
  }
  return 0
}
# Same, with one level of brace expansion ({.env,x}).
function glob_secret_br(g,   a, b, c, pre, inner, suf, m, alt, j) {
  a = index(g, "{"); b = index(g, "}")
  if (a > 0 && b > a) {
    pre = substr(g, 1, a - 1); inner = substr(g, a + 1, b - a - 1); suf = substr(g, b + 1)
    m = split(inner, alt, ",")
    for (j = 1; j <= m; j++) if (glob_secret(bn(pre alt[j] suf))) return 1
    return 0
  }
  return glob_secret(bn(g))
}
# A glob that restricts a recursive search to something specific (*.ts), not a secret name.
function restrictive_glob(g,   lit) {
  lit = bn(g); gsub(/[]*?[{},]/, "", lit)
  return length(lit) >= 3 && !glob_secret_br(g)
}
# A normalised absolute path that names secret material? Sets why.
function sp(p,   b, lb, d, n, parts, suf, i, lp) {
  why = ""
  if (p == "") return 0
  b = bn(p); lb = tolower(b); lp = tolower(p)
  if (b ~ /[*?[]/ && glob_secret(b)) { why = "motif de fichiers de secrets"; return 1 }
  if (lb == ".env" || lb == ".envrc") { why = "fichier d'environnement"; return 1 }
  if (lb ~ /^\.env(\.[a-z0-9_-]+)+$/) {
    n = split(lb, parts, ".")
    suf = parts[n]
    if (!inl("example sample template tpl dist defaults default schema skel skeleton", suf)) { why = "fichier d'environnement"; return 1 }
    return 0
  }
  if (lb ~ /^(prod|production|staging|stage|dev|development|local|test|secrets?|app|docker|backend|frontend|server|api)\.env$/) { why = "fichier d'environnement"; return 1 }
  if (inl(".netrc _netrc .npmrc .pypirc .pgpass .git-credentials .htpasswd .vault-token .dockercfg .credentials.json .claude.json credentials.json", lb)) { why = "fichier d'identifiants"; return 1 }
  if (lb ~ /^(client_secret|service-?account)[a-z0-9_.-]*\.json$/ || lb ~ /-sa-key\.json$/) { why = "fichier d'identifiants"; return 1 }
  if (lb ~ /\.tfstate(\.[a-z0-9._-]+)?$/ || lb ~ /\.tfvars(\.json)?$/) { why = "état ou variables tofu/terraform"; return 1 }
  if (lb ~ /^id_[a-z0-9_.-]+$/ && lb !~ /\.pub$/) { why = "clé privée"; return 1 }
  if (lb ~ /\.(key|p12|pfx|p8|jks|keystore|ppk|kdbx|agekey)$/) { why = "clé ou certificat privé"; return 1 }
  if (!PEMOK && lb ~ /\.pem$/) { why = "clé ou certificat privé"; return 1 }
  d = lp "/"
  if (index(d, "/.ssh/") > 0) {
    if (lb ~ /\.pub$/ || lp ~ /\/\.ssh\/(config|known_hosts|known_hosts\.old)$/) return 0
    why = "matériel privé de ~/.ssh"; return 1
  }
  for (i = 1; i <= ndirs; i++) if (index(d, dirs[i]) > 0) { why = "magasin d'identifiants (" dirs[i] ")"; return 1 }
  if (p ~ /^\/proc\/[^\/]+(\/task\/[^\/]+)?\/environ$/) { why = "environnement d'un processus"; return 1 }
  if (index(lp, "/.terraform.d/credentials") > 0) { why = "magasin d'identifiants"; return 1 }
  if (p ~ /^\/etc\/ssh\/ssh_host_.*_key$/) { why = "clé d'hôte SSH"; return 1 }
  return 0
}
# Protected for writes: kit's config dir, the user settings, and the installed kit's code and settings (lower-cased
# comparison: macOS volumes are case-insensitive; globs are matched against the protected paths).
function protglob(lp,   re, i) {
  re = glob2re(lp)
  for (i = 1; i <= nroots; i++) if (roots[i] ~ re || (roots[i] "/x") ~ re) return 1
  for (i = 1; i <= nfiles; i++) if (files[i] ~ re) return 1
  for (i = 1; i <= nprot; i++) if ((protpre[i] ".json") ~ re) return 1
  return 0
}
function protected(p,   i, lp) {
  lp = tolower(p)
  # a project's settings.local.json is where an agent would grant itself rights (kit perms allow writes settings.json)
  if (lp ~ /\/\.claude\/settings\.local\.json$/) return 1
  if (lp ~ /[*?[]/ && protglob(lp)) return 1
  for (i = 1; i <= nroots; i++) if (lp == roots[i] || index(lp, roots[i] "/") == 1) return 1
  for (i = 1; i <= nfiles; i++) if (lp == files[i]) return 1
  for (i = 1; i <= nprot; i++) if (index(lp, protpre[i]) == 1 && lp ~ /[.]json$/) return 1
  return 0
}
# Is d an ancestor of (or equal to) something protected? (a recursive copy into d could overwrite it)
function holds_prot(p,   d, i) {
  d = tolower(p); if (d != "/") d = d "/"
  for (i = 1; i <= nroots; i++) if (index(roots[i] "/", d) == 1) return 1
  for (i = 1; i <= nfiles; i++) if (index(files[i], d) == 1) return 1
  for (i = 1; i <= nprot; i++) if (index(protpre[i], d) == 1) return 1
  return 0
}
# Is d (a normalised absolute directory) above a credential store? (a recursive search from d would read it)
function above_store(d,   i) {
  if (d == "/" || d == HOME) return 1
  for (i = 1; i <= nsroots; i++) if (index(sroots[i] "/", d "/") == 1) return 1
  return 0
}
function clean(w) { gsub(/\001/, "$", w); return w }
# A word that looks like a path (no spaces, quotes, parentheses...) and has no unknown expansion.
function pathlike(w) { return index(w, "\002") == 0 && w ~ PATHRE }

# Read check of one operand word: the word itself and the tails after "=", "@" and ":" (--x=file, @file, host:file, rev:file).
function chk_read(w,   c, i, ch, cand, alt, j, pre, inner, suf, m, inb, p, nc) {
  w = clean(w)
  if (w == "" || blocked) return
  if (index(w, "\002") > 0) return
  if (w ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) return
  if (!pathlike(w)) return
  nc = 0
  cand[++nc] = w
  for (i = 1; i <= length(w); i++) {
    ch = substr(w, i, 1)
    if (ch == "=" || ch == "@" || ch == ":") cand[++nc] = substr(w, i + 1)
  }
  for (c = 1; c <= nc && !blocked; c++) {
    p = cand[c]
    while (substr(p, 1, 1) == "@" || substr(p, 1, 1) == "=" || substr(p, 1, 1) == "<") p = substr(p, 2)
    if (p == "") continue
    inb = index(p, "{")
    if (inb > 0 && index(p, "}") > inb) {
      pre = substr(p, 1, inb - 1); inner = substr(p, inb + 1); suf = substr(inner, index(inner, "}") + 1); inner = substr(inner, 1, index(inner, "}") - 1)
      m = split(inner, alt, ",")
      for (j = 1; j <= m && !blocked; j++) if (sp(norm(pre alt[j] suf))) block("secret", "lecture d'un fichier de secrets (" why ": " pre alt[j] suf ")")
      continue
    }
    if (sp(norm(p))) block("secret", "lecture d'un fichier de secrets (" why ": " p ")")
  }
}
function chk_write(w, strict,   p) {
  w = clean(w)
  if (w == "" || blocked || !pathlike(w)) return
  p = norm(w)
  if (protected(p)) { block("config", "écriture dans la configuration ou le code gérés par kit (" w ")"); return }
  if (strict && sp(p)) block("secret", "écriture dans un fichier de secrets (" why ": " w ")")
}
# A directory that receives a recursive write (tar -x, unzip -d, rsync, ln targets, find -delete): protected itself, or
# above something protected.
function chk_dir(w,   p) {
  w = clean(w)
  if (w == "" || blocked || !pathlike(w)) return
  p = norm(w)
  if (protected(p) || holds_prot(p)) block("config", "écriture récursive dans la configuration ou le code gérés par kit (" w ")")
}
function chk_redir(op, t) {
  if (blocked || t == "") return
  if (op == "<") chk_read(t)
  else if (index(op, ">") > 0) { chk_write(t, 1); if (op == "<>") chk_read(t) }
}

# --- tokenizer -----------------------------------------------------------------------------------------------
function newlevel(L, kind, senv) {
  nw[L] = 0; nr[L] = 0; nh[L] = 0; pend[L] = ""; hbody[L] = ""; hexp[L] = ""; hsw[L] = ""; inw[L] = 0; wq[L] = 0; wd[L] = ""; pipeout[L] = 0
  pendsec[L] = 0; kindl[L] = kind; par[L] = 0; senvL[L] = senv
}
function reset(L) { nw[L] = 0; nr[L] = 0; pend[L] = ""; hbody[L] = ""; hexp[L] = ""; hsw[L] = ""; pipeout[L] = 0 }
function addc(L, ch) { inw[L] = 1; wd[L] = wd[L] ch }
function endword(L,   x, qd) {
  if (!inw[L]) return
  inw[L] = 0
  x = wd[L]; wd[L] = ""; qd = wq[L]; wq[L] = 0
  if (pend[L] != "") {
    if (pend[L] == "<<" || pend[L] == "<<-") { nh[L]++; hd[L, nh[L]] = x; hdt[L, nh[L]] = (pend[L] == "<<-"); hdq[L, nh[L]] = qd }
    else if (pend[L] == "<<<") hsw[L] = hsw[L] " " x
    else { nr[L]++; rop[L, nr[L]] = pend[L]; rtg[L, nr[L]] = x }
    pend[L] = ""
  } else { nw[L]++; W[L, nw[L]] = x }
}
function heredoc(L, s, i, n,   k, dl, strip, le, ln, cm) {
  for (k = 1; k <= nh[L]; k++) {
    dl = hd[L, k]; strip = hdt[L, k]
    while (i <= n) {
      le = index(substr(s, i), "\n")
      if (le == 0) { ln = substr(s, i); i = n + 1 } else { ln = substr(s, i, le - 1); i += le }
      cm = ln
      if (strip) sub(/^\t+/, "", cm)
      if (cm == dl) break
      hbody[L] = hbody[L] ln "\n"
      if (!hdq[L, k]) hexp[L] = hexp[L] ln "\n"
    }
  }
  return i
}

function analyze(s, senv0,   base, L, n, i, c, c2, q, op, j, k) {
  s = clean2(s)
  if (blocked) return
  if (dep > 8) { block("system", "imbrication trop profonde (eval, bash -c) : analyse impossible"); return }
  dep++
  lv++; base = lv; L = lv
  newlevel(L, 0, senv0)
  n = length(s); i = 1; q = 0
  while (i <= n && !blocked) {
    c = substr(s, i, 1)
    if (q == 1) {
      if (c == "'") q = 0
      else addc(L, (c == "$" ? "\001" : c))
      i++; continue
    }
    if (c == "\\") {
      c2 = substr(s, i + 1, 1)
      if (q == 2) {
        if (c2 == "$" || c2 == "`" || c2 == "\"" || c2 == "\\") { addc(L, (c2 == "$" ? "\001" : c2)); i += 2 }
        else if (c2 == "\n") i += 2
        else { addc(L, c); i++ }
      } else if (c2 == "\n") i += 2
      else { addc(L, (c2 == "$" ? "\001" : c2)); i += 2 }
      continue
    }
    if (q == 2 && c == "\"") { q = 0; inw[L] = 1; i++; continue }
    # command substitution: $( ... ) and `...` (also inside double quotes) are analysed as commands
    if (c == "$" && substr(s, i + 1, 1) == "(") {
      addc(L, "\002")
      lv++; newlevel(lv, 1, senvL[L]); sq[lv] = q; L = lv; q = 0; i += 2; continue
    }
    if (c == "`") {
      if (kindl[L] == 2) {
        endword(L); flush(L)
        q = sq[L]; lv--; L = lv; i++; continue
      }
      addc(L, "\002")
      lv++; newlevel(lv, 2, senvL[L]); sq[lv] = q; L = lv; q = 0; i++; continue
    }
    if (q == 2) { addc(L, c); i++; continue }
    if (c == "'") { q = 1; inw[L] = 1; wq[L] = 1; i++; continue }
    if (c == "\"") { q = 2; inw[L] = 1; wq[L] = 1; i++; continue }
    if (c == " " || c == "\t" || c == "\r") { endword(L); i++; continue }
    if (c == "\n") {
      endword(L)
      if (nh[L] > 0) i = heredoc(L, s, i + 1, n); else i++
      flush(L); nh[L] = 0; continue
    }
    if (c == "#" && !inw[L]) { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
    if (c == ";") { endword(L); flush(L); i++; continue }
    if (c == "|") { endword(L); pipeout[L] = 1; flush(L); i++; continue }
    if (c == "&") {
      if (substr(s, i + 1, 1) == ">") {
        endword(L); op = "&>"; j = i + 2
        if (substr(s, j, 1) == ">") { op = "&>>"; j++ }
        pend[L] = op; i = j; continue
      }
      endword(L); flush(L); i++; continue
    }
    if (c == "(") { endword(L); flush(L); if (kindl[L] == 1) par[L]++; i++; continue }
    if (c == ")") {
      endword(L); flush(L)
      if (kindl[L] == 1) {
        if (par[L] > 0) par[L]--
        else { q = sq[L]; lv--; L = lv }
      }
      i++; continue
    }
    if (c == "<" || c == ">") {
      if (substr(s, i + 1, 1) == "(") { endword(L); i++; continue } # process substitution: the "(" opens a command
      if (inw[L] && wd[L] ~ /^[0-9]+$/) { inw[L] = 0; wd[L] = "" } else endword(L)
      op = ""; j = i
      while (j <= n && (substr(s, j, 1) == "<" || substr(s, j, 1) == ">") && length(op) < 3) { op = op substr(s, j, 1); j++ }
      if (substr(s, j, 1) == "-" && op == "<<") { op = "<<-"; j++ }
      if (substr(s, j, 1) == "|" && op == ">") { op = ">|"; j++ }
      if (substr(s, j, 1) == "&" && index(op, "<<") == 0) {
        j++
        k = 0
        while (substr(s, j, 1) ~ /[0-9-]/) { j++; k++ }
        if (k > 0) { i = j; continue } # fd duplication: no target
        op = op "&"
      }
      pend[L] = op; i = j; continue
    }
    addc(L, c); i++
  }
  endword(L)
  while (lv > base) { flush(lv); lv-- }
  flush(base)
  lv = base - 1
  dep--
}
function clean2(s) { gsub(/\001/, "$", s); gsub(/\002/, " ", s); return s }

# --- commands ------------------------------------------------------------------------------------------------
function skipo(L, k, n, withargs,   v) {
  while (k <= n) {
    v = W[L, k]
    if (v == "--") return k + 1
    if (substr(v, 1, 1) != "-" || v == "-") return k
    k += (index(withargs, " " v " ") > 0 ? 2 : 1)
  }
  return k
}
# Does a word expand a variable named like a secret? ${!x} (indirect) is unknown: refused, except ${!prefix@} (names only).
function secretvar(v,   lv2, rest, nm) {
  lv2 = tolower(v)
  while (match(lv2, /[$][{]?[!]?[a-z_][a-z0-9_]*/)) {
    nm = substr(lv2, RSTART, RLENGTH); rest = substr(lv2, RSTART + RLENGTH)
    lv2 = rest
    if (index(nm, "!") > 0) {
      if (substr(rest, 1, 2) == "@}" || substr(rest, 1, 2) == "*}") continue
      return 1
    }
    sub(/^[$][{]?/, "", nm)
    if (nm ~ NAMERE) {
      if (substr(rest, 1, 2) == ":+" || substr(rest, 1, 1) == "+") continue
      return 1
    }
  }
  return 0
}
# A command line that legitimately consumes a secret from stdin (a pipe or here-string into it is a use, not a print).
function consumer_ok(L, n,   s, j) {
  s = " "
  for (j = 1; j <= n; j++) s = s tolower(W[L, j]) " "
  if (s ~ /--password-stdin|--with-token| wrangler .*secret (put|bulk) | gh secret set | docker login | kit secrets add /) return 1
  if (s ~ / curl .* (-d|--data|--data-binary|--data-raw) @- /) return 1
  return 0
}
function code_scan(str, senv,   t, n, a, i, lst) {
  lst = tolower(str)
  if (str ~ ENVDUMP) { block("secret", "affichage de tout l'environnement depuis un interpréteur"); return }
  if (lst ~ ENVACCESS) {
    if (senv) { block("secret", "accès à l'environnement depuis un interpréteur dans kit secrets run"); return }
    if (lst ~ NAMERE) { block("secret", "lecture d'une variable secrète depuis un interpréteur"); return }
  }
  gsub(CODEJUNK, " ", str)
  n = split(str, a, " ")
  for (i = 1; i <= n && !blocked; i++) {
    t = a[i]
    if (index(t, "/") > 0 || substr(t, 1, 1) == "." || substr(t, 1, 1) == "~") chk_read(t)
  }
}
function jq_env(f) { return f ~ /(^|[^A-Za-z0-9_.$])env([^A-Za-z0-9_]|$)/ || index(f, "$ENV") > 0 || index(f, "\001ENV") > 0 }
# The words a..b of level L as one quoted command line (find -exec ... ;).
function quote_join(L, a, b,   s, j, w) {
  s = ""
  for (j = a; j <= b; j++) { w = W[L, j]; gsub(/'/, "'\\''", w); s = s " '" w "'" }
  return s
}

function runcmd(L, k, n, senv, pipeo, hb,   w, cmd, j, v, s, na, ja, np, hasi, e, d) {
  while (k <= n) {
    w = W[L, k]
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || (w in RES)) { k++; continue }
    cmd = bn(w)
    if (cmd == "sudo" || cmd == "doas") { k = skipo(L, k + 1, n, " -u -g -h -p -C -D -R -T -U -r -t "); continue }
    if (cmd == "env") {
      k++
      while (k <= n) {
        v = W[L, k]
        if (v == "--") { k++; break }
        if (v ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { k++; continue }
        if (substr(v, 1, 1) == "-") { k += (index(" -u -C -S --unset --chdir --split-string ", " " v " ") > 0 ? 2 : 1); continue }
        break
      }
      if (k > n) { block("secret", "lecture de l'environnement du processus (env)"); return }
      continue
    }
    if (cmd == "timeout") { k = skipo(L, k + 1, n, " -s -k --signal --kill-after "); k++; continue }
    if (cmd == "nice") { k = skipo(L, k + 1, n, " -n --adjustment "); continue }
    if (cmd == "ionice") { k = skipo(L, k + 1, n, " -c -n -p -P -u "); continue }
    if (cmd == "stdbuf" || cmd == "nohup" || cmd == "exec" || cmd == "builtin" || cmd == "setsid" || cmd == "unbuffer" || cmd == "caffeinate" || cmd == "chronic") { k = skipo(L, k + 1, n, " -a "); continue }
    if (cmd == "command") { if (W[L, k + 1] == "-v" || W[L, k + 1] == "-V") return; k = skipo(L, k + 1, n, ""); continue }
    if (cmd == "xargs") {
      for (j = k + 1; j < n; j++) if (W[L, j] == "-a" || W[L, j] == "--arg-file") chk_read(W[L, j + 1])
      k = skipo(L, k + 1, n, " -n -I -L -P -d -E -s -a -J ")
      continue
    }
    if (cmd == "watch") { k = skipo(L, k + 1, n, " -n -d "); continue }
    break
  }
  if (k > n) return
  cmd = bn(W[L, k])
  na = n - k

  # kit secrets: edit prints decrypted values; run injects them, so what runs there must not print the environment.
  if (cmd == "kit" && W[L, k + 1] == "secrets") {
    if (W[L, k + 2] == "edit") { block("secret", "kit secrets edit affiche les secrets déchiffrés"); return }
    if (W[L, k + 2] == "run") {
      for (j = k + 3; j <= n; j++) if (W[L, j] == "--") break
      if (j < n) { runcmd(L, j + 1, n, 1, pipeo, hb); return }
      # no "--": the command starts after the options (-g, -e ENV)
      j = k + 3
      while (j <= n && substr(W[L, j], 1, 1) == "-") j += (W[L, j] == "-e" ? 2 : 1)
      if (j <= n) runcmd(L, j, n, 1, pipeo, hb)
      return
    }
  }
  if (cmd == "kit" && W[L, k + 1] == "index") {
    for (j = k + 2; j <= n; j++) {
      if (W[L, j] == "--out") chk_write(W[L, j + 1], 1)
      else if (index(W[L, j], "--out=") == 1) chk_write(substr(W[L, j], 7), 1)
    }
  }
  # kit project add|perms --dir: never the home directory, / or a directory holding the user settings
  if (cmd == "kit" && W[L, k + 1] == "project") {
    for (j = k + 2; j <= n; j++) {
      v = ""
      if (W[L, j] == "--dir") v = W[L, j + 1]
      else if (index(W[L, j], "--dir=") == 1) v = substr(W[L, j], 7)
      v = clean(v)
      if (v != "" && pathlike(v)) { d = norm(v); if (d == "/" || d == HOME || tolower(d) == tolower(CH)) block("config", "kit project --dir sur le dossier personnel ou les réglages de l'utilisateur (" v ")") }
    }
  }
  # nested shells and eval: the string is a command line
  if (inl("bash sh zsh dash ksh ash fish csh tcsh", cmd)) {
    j = k + 1
    while (j <= n) {
      v = W[L, j]
      if (v == "--") { j++; break }
      if (v == "-o" || v == "+o" || v == "-O" || v == "+O") { j += 2; continue }
      if (v ~ /^-[A-Za-z]*c[A-Za-z]*$/) {
        if (senv && v ~ /x/) { block("secret", "xtrace dans kit secrets run (affiche les valeurs)"); return }
        j++
        if (W[L, j] == "--") j++
        if (j <= n) analyze(W[L, j], senv)
        return
      }
      if (senv && v ~ /^-[A-Za-z]*x/) { block("secret", "xtrace dans kit secrets run (affiche les valeurs)"); return }
      if (substr(v, 1, 1) != "-" && substr(v, 1, 1) != "+") break
      j++
    }
    if (j <= n && bn(W[L, j]) == "tofu.sh") { tfchk(L, j, n); return }
    if (hb != "") analyze(hb, senv)
  }
  if (inl("script flock su runuser", cmd)) {
    for (j = k + 1; j < n; j++) if (W[L, j] ~ /^-[A-Za-z]*c$/ || W[L, j] == "--command") { analyze(W[L, j + 1], senv); break }
  }
  if (cmd == "eval") {
    s = ""
    for (j = k + 1; j <= n; j++) s = s " " W[L, j]
    analyze(s, senv)
    return
  }
  if (cmd == "trap") {
    for (j = k + 1; j <= n; j++) if (substr(W[L, j], 1, 1) != "-") { analyze(W[L, j], senv); break }
    return
  }

  # environment dumps
  if (cmd == "printenv") {
    if (na == 0) { block("secret", "lecture de l'environnement du processus (printenv)"); return }
    for (j = k + 1; j <= n; j++) if (tolower(W[L, j]) ~ NAMERE) { block("secret", "affichage d'une variable secrète (printenv)"); return }
    return
  }
  if (cmd == "set") {
    if (na == 0) { block("secret", "lecture de l'environnement du shell (set)"); return }
    if (senv) for (j = k + 1; j <= n; j++) if (W[L, j] ~ /^-[A-Za-z]*x/ || W[L, j] == "xtrace") { block("secret", "xtrace dans kit secrets run (affiche les valeurs)"); return }
  }
  if (cmd == "export" && (na == 0 || W[L, k + 1] == "-p")) { block("secret", "lecture de l'environnement du shell (export)"); return }
  if (cmd == "declare" || cmd == "typeset") {
    np = 0; ja = 0; hasi = 0
    for (j = k + 1; j <= n; j++) {
      if (substr(W[L, j], 1, 1) == "-") { if (W[L, j] ~ /[xp]/) ja = 1; if (W[L, j] ~ /p/) hasi = 1 }
      else { np++; if (tolower(W[L, j]) ~ NAMERE) e = 1 }
    }
    if (np == 0 && (na == 0 || ja)) { block("secret", "lecture de l'environnement du shell (declare)"); return }
    if (hasi && (senv || e)) { block("secret", "declare -p affiche la valeur d'une variable"); return }
  }
  # echo/printf of a variable named like a secret: a pipe is a use only into a known consumer (checked at the next command)
  if (cmd == "echo" || cmd == "printf" || cmd == "print") {
    for (j = k + 1; j <= n; j++) {
      v = W[L, j]
      if (index(v, "$") == 0) continue
      if (senv) { block("secret", "affichage d'une variable d'environnement injectée par kit secrets run"); return }
      if (secretvar(v)) {
        if (!pipeo) { block("secret", "affichage d'une variable secrète (" v ")"); return }
        pendsec[L] = 1
      }
    }
    return
  }

  # decryption and token printing
  if (cmd == "sops") {
    for (j = k + 1; j <= n; j++) if (inl("-d --decrypt decrypt exec-env exec-file edit", W[L, j])) { block("secret", "déchiffrement manuel de secrets (sops)"); return }
    return
  }
  if (cmd == "age") {
    for (j = k + 1; j <= n; j++) if (W[L, j] == "-d" || W[L, j] == "--decrypt") { block("secret", "déchiffrement manuel de secrets (age)"); return }
  }
  if (cmd == "age-keygen") {
    hasi = 0
    for (j = k + 1; j <= n; j++) if (W[L, j] == "-o" || W[L, j] == "-y" || W[L, j] == "--version") hasi = 1
    if (!hasi) { block("secret", "age-keygen imprime la clé privée : utilise -o <fichier>"); return }
  }
  if (cmd == "ssh-keygen") {
    for (j = k + 1; j <= n; j++) if (W[L, j] ~ /^-[A-Za-z]*y/) { block("secret", "ssh-keygen -y lit une clé privée"); return }
  }
  if (cmd == "gh" && W[L, k + 1] == "auth") {
    if (W[L, k + 2] == "token") { block("secret", "affichage d'un jeton (gh auth token)"); return }
    for (j = k + 2; j <= n; j++) if (W[L, j] == "-t" || W[L, j] == "--show-token") { block("secret", "affichage d'un jeton (gh auth status)"); return }
  }
  s = " " tolower(cmd) " "
  for (j = k + 1; j <= n && j <= k + 8; j++) s = s tolower(W[L, j]) " "
  if (s ~ / kubectl .*get +secrets? / && s ~ / (-o|--output)[ =]*(yaml|json|jsonpath|go-template)/) { block("secret", "kubectl get secret affiche des valeurs de secrets"); return }
  if (s ~ / kubectl config view .*--raw/) { block("secret", "kubectl config view --raw affiche des identifiants"); return }
  if (s ~ / aws secretsmanager get-secret-value / || s ~ / aws ssm get-parameters? .*--with-decryption/ || s ~ / gcloud secrets versions access / || s ~ / (op read|bw get|pass show|vault kv get) /) { block("secret", "commande qui affiche la valeur d'un secret"); return }
  if (s ~ / security .*find-(generic|internet)-password / && s ~ / -[a-z]*[wg]/) { block("secret", "lecture d'un mot de passe du trousseau"); return }
  if (senv && cmd == "curl") {
    for (j = k + 1; j <= n; j++) if (W[L, j] ~ /^-[A-Za-z]*v/ || W[L, j] == "--verbose" || index(W[L, j], "--trace") == 1) { block("secret", "curl -v ou --trace dans kit secrets run affiche les en-têtes"); return }
  }
  if (cmd == "tofu" || cmd == "terraform" || cmd == "tofu.sh") { tfchk(L, k, n); if (blocked) return }
  if (cmd == "docker" || cmd == "docker-compose" || cmd == "podman") { dockchk(L, k, n, cmd); if (blocked) return }

  # interpreters: -c / -e strings and heredoc bodies are code; scan them for secret paths and environment access
  if (inl("python python3 node nodejs ruby perl php deno bun lua", cmd) || cmd ~ /^python[0-9.]+$/) {
    for (j = k + 1; j <= n; j++) {
      v = W[L, j]
      if (v ~ /^-[A-Za-z]*[ceEpr][A-Za-z]*$/ || v == "--eval" || v == "--print" || v == "-eval") { if (j < n) { code_scan(clean(W[L, j + 1]), senv) }; break }
      if (v ~ /^--(eval|print)=/) { code_scan(clean(substr(v, index(v, "=") + 1)), senv); break }
    }
    if (hb != "") code_scan(hb, senv)
  }
  if (cmd == "git") { gitchk(L, k, n); return }
  if (cmd == "cd" || cmd == "pushd") {
    v = ""
    for (j = k + 1; j <= n; j++) if (substr(W[L, j], 1, 1) != "-") { v = W[L, j]; break }
    if (v == "") CUR = HOME
    else if (v != "-") { v = clean(v); if (pathlike(v)) { s = norm(v); if (index(s, "$") == 0) CUR = s } }
    return
  }

  mutchk(L, k, n, cmd)
  if (blocked) return

  # read checks by class
  if (inl(TEXTS, cmd)) return
  if (inl(NOCHK, cmd)) return
  if (cmd == "find") { findscan(L, k, n); return }
  if (inl(PATS, cmd)) { patscan(L, k, n, cmd, senv); return }
  if (inl(COPYS, cmd)) { copyscan(L, k, n); return }
  if (cmd == "openssl" && inl("x509 verify crl", W[L, k + 1])) PEMOK = 1
  defscan(L, k, n, cmd)
  PEMOK = 0
}

function defscan(L, k, n, cmd,   j, v, skipd, eq, sshl, envok) {
  sshl = inl(SSHLIKE, cmd)
  envok = inl("node nodejs deno bun docker-compose", cmd)
  if (cmd == "docker") for (j = k + 1; j <= n; j++) if (W[L, j] == "compose") envok = 1
  skipd = 0
  for (j = k + 1; j <= n && !blocked; j++) {
    v = W[L, j]
    if (skipd) { skipd = 0; continue }
    if (sshl && index(SSHARGS, " " v " ") > 0) { skipd = 1; continue }
    if (envok && v == "--env-file") { skipd = 1; continue }
    if (envok && index(v, "--env-file=") == 1) continue
    if (v == "--") continue
    if (substr(v, 1, 1) == "-" && v != "-") { eq = index(v, "="); if (eq > 0) chk_read(substr(v, eq + 1)); continue }
    chk_read(v)
  }
}
function findscan(L, k, n,   j, v, i, e, hasi, ns, st) {
  hasi = 0
  for (j = k + 1; j <= n && !blocked; j++) {
    v = W[L, j]
    if (inl("-exec -execdir -ok -okdir", v)) {
      hasi = 1
      for (e = j + 1; e <= n; e++) if (W[L, e] == ";" || W[L, e] == "+") break
      if (e > j + 1) analyze(quote_join(L, j + 1, e - 1), 0)
      j = e
    }
  }
  # start points (the words before the first expression): the target of -delete; -fprint* name the file they write
  ns = 0
  for (j = k + 1; j <= n; j++) {
    v = W[L, j]
    if (inl("-H -L -P", v)) continue
    if ((substr(v, 1, 1) == "-" && v != "-") || v == "(" || v == "!") break
    st[++ns] = v
  }
  for (; j <= n && !blocked; j++) {
    v = W[L, j]
    if (v == "-delete") { for (i = 1; i <= ns; i++) chk_dir(st[i]) }
    if (inl("-fprint -fprint0 -fprintf -fls", v)) chk_write(W[L, j + 1], 1)
  }
  if (hasi && !blocked) { DOTOK = 1; defscan(L, k, n, "find"); DOTOK = 0 }
}
function copyscan(L, k, n,   j, v, np, tdir, skipd, i, rec, merge, src, dest) {
  np = 0; tdir = ""; skipd = 0; rec = 0
  for (j = k + 1; j <= n; j++) {
    v = W[L, j]
    if (skipd) { skipd = 0; continue }
    if (v == "-t" || v == "--target-directory") { tdir = W[L, j + 1]; skipd = 1; continue }
    if (index(v, "--target-directory=") == 1) { tdir = substr(v, 20); continue }
    if (index(SSHARGS " -e --rsh --exclude --include --filter ", " " v " ") > 0) { skipd = 1; continue }
    if (v ~ /^-[A-Za-z]*[rRa]/ || v == "--recursive" || v == "--archive") rec = 1
    if (substr(v, 1, 1) == "-" && v != "-") continue
    np++; PP[L, np] = v
  }
  # the destination of a copy is not read (cp .env.example .env): only the sources are checked
  for (i = 1; i <= (tdir != "" ? np : np - 1) && !blocked; i++) chk_read(PP[L, i])
}
# Where a copy, move or link lands: the destination, its basename-of-source children, and (recursive or rsync with a
# trailing slash) the whole destination directory when it holds something protected.
function destchk(L, np, tdir, cmd, rec,   dest, i, s, b, first) {
  first = (tdir != "" ? 1 : 1)
  dest = (tdir != "" ? tdir : MP[L, np])
  chk_write(dest, 0)
  for (i = 1; i <= (tdir != "" ? np : np - 1) && !blocked; i++) {
    s = clean(MP[L, i])
    if (s == "" || s == "-") continue
    if (s == "." || s ~ /\/\.?$/ ) {
      if (rec || cmd == "rsync") chk_dir(dest)
      continue
    }
    b = bn(s)
    chk_write(dest "/" b, 0)
  }
}
function patscan(L, k, n, cmd, senv,   j, v, have, patdone, noopt, isjq, isawk, issed, isgrep, rec, restr, dirs_n, d, i, g, incl, nd) {
  have = 0; isjq = inl("jq yq gojq jaq", cmd); isawk = inl("awk gawk mawk nawk", cmd); issed = inl("sed gsed", cmd)
  isgrep = inl("grep egrep fgrep rg ag ack", cmd)
  rec = (cmd == "rg" || cmd == "ag" || cmd == "ack"); restr = 0; nd = 0
  for (j = k + 1; j <= n; j++) {
    v = W[L, j]
    if (inl("-e --regexp --expression -f --file --from-file", v)) have = 1
    if (isgrep && (v ~ /^-[A-Za-z]*[rR]/ || v == "--recursive" || v == "--dereference-recursive" || v == "-d" && W[L, j + 1] == "recurse")) rec = 1
  }
  patdone = have; noopt = 0
  for (j = k + 1; j <= n && !blocked; j++) {
    v = W[L, j]
    if (!noopt && v == "--") { noopt = 1; continue }
    if (!noopt && substr(v, 1, 1) == "-" && v != "-") {
      if (isjq && (v == "--arg" || v == "--argjson")) { j += 2; continue }
      if (isjq && (v == "--slurpfile" || v == "--rawfile" || v == "--argfile")) { chk_read(W[L, j + 2]); j += 2; continue }
      if (isjq && (v == "--args" || v == "--jsonargs")) break
      if (v == "-e" || v == "--regexp" || v == "--expression") {
        if (isjq && jq_env(W[L, j + 1])) block("secret", "jq lit l'environnement (env)")
        if (issed) sedscan(clean(W[L, j + 1]))
        j++; continue
      }
      if (v == "-f" || v == "--file" || v == "--from-file") { chk_read(W[L, j + 1]); j++; continue }
      if (isgrep && (v == "-g" || v == "--glob" || v == "--include" || v == "-t" || v == "-T" || v == "--type" || v == "--type-add")) {
        g = clean(W[L, j + 1])
        if (v == "-t" || v == "--type") restr = 1
        else { DOTOK = 1; if (glob_secret_br(g)) block("secret", "recherche limitée à des fichiers de secrets (" g ")"); DOTOK = 0; if (restrictive_glob(g)) restr = 1 }
        j++; continue
      }
      if (isgrep && index(v, "--include=") == 1) {
        g = clean(substr(v, 11)); DOTOK = 1; if (glob_secret_br(g)) block("secret", "recherche limitée à des fichiers de secrets (" g ")"); DOTOK = 0
        if (restrictive_glob(g)) restr = 1
        continue
      }
      if (isgrep && index(v, "--glob=") == 1) {
        g = clean(substr(v, 8)); DOTOK = 1; if (glob_secret_br(g)) block("secret", "recherche limitée à des fichiers de secrets (" g ")"); DOTOK = 0
        if (restrictive_glob(g)) restr = 1
        continue
      }
      if (isawk) { if (v == "-v" || v == "-F") { j++; continue } }
      else if (index(" -A -B -C -m -D -j --max-count --after-context --before-context --context ", " " v " ") > 0 || (v == "-d" && !isjq)) { j++; continue }
      continue
    }
    if (!patdone) {
      patdone = 1
      if (isjq && jq_env(v)) block("secret", "jq lit l'environnement (env)")
      if (issed) sedscan(clean(v))
      if (isawk) awkscan(clean(v), senv)
      continue
    }
    if (rec) { nd++; dlist[L, nd] = v }
    chk_read(v)
  }
  if (rec && !blocked) {
    if (nd == 0) { if (!restr && above_store(CUR)) block("secret", "recherche récursive depuis un dossier qui contient des identifiants (" CUR ")") }
    else for (i = 1; i <= nd && !blocked; i++) {
      d = clean(dlist[L, i])
      if (pathlike(d) && !restr && above_store(norm(d))) block("secret", "recherche récursive depuis un dossier qui contient des identifiants (" d ")")
    }
  }
}
# sed script: the w/W commands (and the w flag of s) write a file; e runs a command.
function sedscan(s,   rest, fr, f) {
  rest = s
  while (match(rest, /(^|[;{}!\n])[ \t]*([0-9$]+|\/[^\/]*\/)?[ \t]*[wW][ \t]*[^ \t;}]+/)) {
    fr = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    sub(/^[;{}! \t\n]*([0-9$]+|\/[^\/]*\/)?[ \t]*[wW][ \t]*/, "", fr)
    chk_write(fr, 1)
  }
  rest = s
  while (match(rest, /s\/[^\/]*\/[^\/]*\/[gipIm0-9]*w[ \t]*[^ \t;}]+/)) {
    fr = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    sub(/^s\/[^\/]*\/[^\/]*\/[gipIm0-9]*w[ \t]*/, "", fr)
    chk_write(fr, 1)
  }
  rest = s
  while (match(rest, /(^|[;{}!\n])[ \t]*([0-9$]+|\/[^\/]*\/)?[ \t]*e[ \t]+[^;}]+/)) {
    fr = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    sub(/^[;{}! \t\n]*([0-9$]+|\/[^\/]*\/)?[ \t]*e[ \t]+/, "", fr)
    analyze(fr, 0)
  }
}
# awk program: system() and | "cmd" run commands, print > "file" writes, getline reads, ENVIRON dumps the environment.
function awkscan(p, senv,   tmp, rest, str, hassys, hasred) {
  if (p ~ /in[ \t]+ENVIRON/ || (senv && p ~ /ENVIRON/)) { block("secret", "awk lit l'environnement (ENVIRON)"); return }
  if (p ~ /getline/) code_scan(p, senv)
  tmp = p; gsub(/"[^"]*"/, "\"\"", tmp)
  hassys = (tmp ~ /system[ \t]*\(/ || tmp ~ /\|[ \t]*""/)
  hasred = (tmp ~ /(print|printf)[^;}]*>/)
  if (!hassys && !hasred) return
  rest = p
  while (match(rest, /"[^"]*"/)) {
    str = substr(rest, RSTART + 1, RLENGTH - 2); rest = substr(rest, RSTART + RLENGTH)
    if (hassys) analyze(str, 0)
    if (hasred) chk_write(str, 1)
  }
}
function gitchk(L, k, n,   j, v, sub1, patdone, afterdd, gdir, wt, np, e, d, nn) {
  j = k + 1; sub1 = ""; gdir = ""; wt = ""
  while (j <= n) {
    v = W[L, j]
    if (v == "-C") { gdir = W[L, j + 1]; j += 2; continue }
    if (v == "-c") {
      if (W[L, j + 1] ~ /^alias\.[^=]*=!/) { e = W[L, j + 1]; analyze(substr(e, index(e, "!") + 1), 0) }
      j += 2; continue
    }
    if (v == "--git-dir" || v == "--namespace") { j += 2; continue }
    if (v == "--work-tree") { wt = W[L, j + 1]; j += 2; continue }
    if (index(v, "--work-tree=") == 1) { wt = substr(v, 13); j++; continue }
    if (substr(v, 1, 1) == "-") { j++; continue }
    sub1 = v; break
  }
  if (sub1 == "commit") { ncommit++; cdir[ncommit] = (gdir != "" ? norm(clean(gdir)) : CUR) }
  # a mutating subcommand run against kit's own directories (git -C ~/.config/claude-kit checkout -- .)
  if (inl("checkout restore reset clean rm mv apply merge pull stash switch am cherry-pick rebase revert add commit init clone", sub1)) {
    if (gdir != "") chk_dir(gdir)
    if (wt != "") chk_dir(wt)
  }
  # output files and destinations
  np = 0
  for (d = j + 1; d <= n; d++) {
    v = W[L, d]
    if (v == "--output" || (v == "-o" && (sub1 == "archive" || sub1 == "format-patch"))) {
      if (sub1 == "format-patch") chk_dir(W[L, d + 1]); else chk_write(W[L, d + 1], 1)
      d++; continue
    }
    if (index(v, "--output=") == 1) { chk_write(substr(v, 10), 1); continue }
    if (index(v, "--output-directory=") == 1) { chk_dir(substr(v, 20)); continue }
    if (substr(v, 1, 1) != "-") { np++; GP[L, np] = v }
  }
  if (sub1 == "clone") for (d = 2; d <= np; d++) chk_dir(GP[L, d])
  if (sub1 == "worktree" && GP[L, 1] == "add") for (d = 2; d <= np; d++) chk_dir(GP[L, d])
  if (sub1 == "bundle" && GP[L, 1] == "create" && np >= 2) chk_write(GP[L, 2], 1)
  if (sub1 == "rebase") {
    for (d = j + 1; d <= n; d++) {
      v = W[L, d]
      if (v == "-x" || v == "--exec") { analyze(W[L, d + 1], 0); d++ }
      else if (index(v, "--exec=") == 1) analyze(substr(v, 8), 0)
    }
  }
  if (!inl("show diff log blame cat-file grep add commit annotate whatchanged format-patch archive", sub1)) return
  if (sub1 == "log" || sub1 == "whatchanged") {
    # the log prints file contents only with a patch option
    patdone = 0
    for (d = j + 1; d <= n; d++) if (W[L, d] == "-p" || W[L, d] == "--patch" || W[L, d] == "-u" || W[L, d] == "--cc" || W[L, d] == "-c") patdone = 1
    if (!patdone) return
  }
  patdone = (sub1 != "grep"); afterdd = 0
  for (j = j + 1; j <= n && !blocked; j++) {
    v = W[L, j]
    if (!afterdd && v == "--") { afterdd = 1; continue }
    if (!afterdd && substr(v, 1, 1) == "-" && v != "-") {
      if (inl("-m -am --message -F --file -S -G -e --grep --author --format --pretty -n --date --since --until -U --abbrev --output -o", v)) j++
      continue
    }
    if (!patdone) { patdone = 1; continue }
    chk_read(v)
  }
}
# tofu / terraform / the infra wrapper: apply and destroy are the user's; state and outputs can print secrets.
function tfchk(L, k, n,   j, v, sub1, hasj) {
  sub1 = ""
  for (j = k + 1; j <= n; j++) {
    v = W[L, j]
    if (v == "apply" || v == "destroy") { block("config", "tofu/terraform " v " : c'est l'utilisateur qui l'applique"); return }
    if (sub1 == "" && substr(v, 1, 1) != "-" && inl("show output state console import plan validate init fmt providers version", v)) sub1 = v
    if (v == "-out" || v == "-state-out" || v == "-backup") { chk_write(W[L, j + 1], 1); }
    else if (index(v, "-out=") == 1) chk_write(substr(v, 6), 1)
    else if (index(v, "-state-out=") == 1) chk_write(substr(v, 12), 1)
  }
  hasj = 0
  for (j = k + 1; j <= n; j++) if (W[L, j] == "-json" || W[L, j] == "-raw") hasj = 1
  if (sub1 == "show" && hasj) { block("secret", "tofu show -json imprime l'état et les valeurs sensibles"); return }
  if (sub1 == "output" && hasj) { block("secret", "tofu output -json|-raw imprime les sorties sensibles"); return }
  if (sub1 == "console") { block("secret", "tofu console lit l'état"); return }
  if (sub1 == "state") for (j = k + 1; j <= n; j++) if (W[L, j] == "pull" || W[L, j] == "show") { block("secret", "tofu state " W[L, j] " imprime l'état"); return }
}
# docker compose: config prints interpolated secrets; up/build/run on a compose file that gives the container the host.
function dockchk(L, k, n, cmd,   j, v, c0, sub1, nf, files_n, cf, ok, f, ctx, skipd) {
  c0 = k + 1
  if (cmd == "docker" || cmd == "podman") {
    for (j = k + 1; j <= n && j <= k + 6; j++) if (W[L, j] == "compose") { c0 = j + 1; break }
    if (j > n || j > k + 6 || W[L, j] != "compose") {
      # docker build / buildx build / image build: the context must not be / or $HOME
      for (j = k + 1; j <= n; j++) if (W[L, j] == "build") break
      if (j <= n) {
        ctx = ""; skipd = 0
        for (c0 = j + 1; c0 <= n; c0++) {
          v = W[L, c0]
          if (skipd) { skipd = 0; continue }
          if (inl("-f --file -t --tag --build-arg --target --platform --secret --ssh --network --cache-from --cache-to --label --iidfile --output -o", v)) { skipd = 1; continue }
          if (substr(v, 1, 1) == "-") continue
          ctx = v
        }
        if (ctx != "" && pathlike(clean(ctx)) && (norm(clean(ctx)) == HOME || norm(clean(ctx)) == "/")) block("config", "docker build avec / ou $HOME comme contexte")
      }
      return
    }
  }
  sub1 = ""; nf = 0; skipd = 0
  for (j = c0; j <= n; j++) {
    v = W[L, j]
    if (skipd) { skipd = 0; continue }
    if (v == "-f" || v == "--file") { nf++; cfile[L, nf] = W[L, j + 1]; skipd = 1; continue }
    if (index(v, "--file=") == 1) { nf++; cfile[L, nf] = substr(v, 8); continue }
    if (inl("-p --project-name --env-file --profile --project-directory --ansi --parallel --progress", v)) { skipd = 1; continue }
    if (substr(v, 1, 1) == "-") continue
    sub1 = v; break
  }
  if (sub1 == "config") {
    ok = 0
    for (j = c0; j <= n; j++) if (inl("--services --volumes --images --profiles -q --quiet --help -h", W[L, j])) ok = 1
    if (!ok) block("secret", "docker compose config imprime les variables interpolées (secrets compris)")
    return
  }
  if (sub1 == "up" || sub1 == "build" || sub1 == "run" || sub1 == "create") {
    if (nf == 0) {
      cfile[L, 1] = "compose.yaml"; cfile[L, 2] = "compose.yml"; cfile[L, 3] = "docker-compose.yml"; cfile[L, 4] = "docker-compose.yaml"; nf = 4
    }
    for (j = 1; j <= nf && !blocked; j++) composefile(norm(clean(cfile[L, j])))
  }
}
function composefile(f,   line, l) {
  if ((getline line < f) < 0) return        # missing file: fail open
  do {
    l = tolower(line); sub(/[ \t]#.*$/, "", l)
    if (l ~ /privileged:[ \t]*["']?true/) { block("config", "compose : privileged: true"); break }
    if (l ~ /(pid|network_mode|ipc|userns_mode|uts):[ \t]*["']?host/) { block("config", "compose : espace de noms de l'hôte (pid/network/ipc: host)"); break }
    if (l ~ /^[ \t-]*["']?([\/]|~|[$][{]?home[}]?)(["']|:|[ \t]|$)/ || l ~ /^[ \t-]*["']?[\/]var[\/]run[\/]docker[.]sock/ || l ~ /^[ \t-]*["']?[\/]run[\/]docker[.]sock/ || l ~ /docker[.]sock[:"' \t]/) { block("config", "compose : montage de / ou $HOME ou du socket docker"); break }
    if (l ~ /source:[ \t]*["']?([\/]|~|[$][{]?home[}]?)["']?[ \t]*$/ || l ~ /(context|build):[ \t]*["']?([\/]|~|[$][{]?home[}]?)["']?[ \t]*$/) { block("config", "compose : montage ou contexte de build sur / ou $HOME"); break }
  } while ((getline line < f) > 0)
  close(f)
}
function mutchk(L, k, n, cmd,   j, v, np, i, hasi, tdir, all, dest, skipd, rec, ex, d) {
  np = 0; tdir = ""; hasi = 0; skipd = 0; rec = 0
  if (cmd == "curl" || cmd == "wget") {
    for (j = k + 1; j <= n; j++) {
      v = W[L, j]
      if (v == "-o" || v == "--output" || v == "-O" && cmd == "wget" || v == "--output-document" || v == "-P" || v == "--directory-prefix") { chk_write(W[L, j + 1], 0); j++ }
      else if (index(v, "--output=") == 1) chk_write(substr(v, 10), 0)
      else if (index(v, "--output-document=") == 1) chk_write(substr(v, 19), 0)
      else if (index(v, "--directory-prefix=") == 1) chk_write(substr(v, 20), 0)
      else if (cmd == "curl" && v ~ /^-o./ && substr(v, 1, 2) != "--") chk_write(substr(v, 3), 0)
      else if (cmd == "wget" && v ~ /^-O./) chk_write(substr(v, 3), 0)
    }
    return
  }
  if (cmd == "dd") {
    for (j = k + 1; j <= n; j++) if (index(W[L, j], "of=") == 1) chk_write(substr(W[L, j], 4), 1)
    return
  }
  if (cmd == "sort") {
    for (j = k + 1; j <= n; j++) {
      v = W[L, j]
      if (v == "-o" || v == "--output") { chk_write(W[L, j + 1], 1); j++ }
      else if (index(v, "--output=") == 1) chk_write(substr(v, 10), 1)
      else if (v ~ /^-[A-Za-z]*o./ && substr(v, 1, 2) != "--") chk_write(substr(v, index(v, "o") + 1), 1)
    }
    return
  }
  if (cmd == "uniq") {
    for (j = k + 1; j <= n; j++) if (substr(W[L, j], 1, 1) != "-") { np++; if (np == 2) chk_write(W[L, j], 1) }
    return
  }
  if (cmd == "tar" || cmd == "bsdtar") {
    ex = 0; d = ""
    for (j = k + 1; j <= n; j++) {
      v = W[L, j]
      if (v == "--extract" || v == "--get" || v ~ /^-[A-Za-z]*x/ || (j == k + 1 && v ~ /^[A-Za-z]*x/)) ex = 1
      if (v == "-C" || v == "--directory") { d = W[L, j + 1]; j++ }
      else if (index(v, "--directory=") == 1) d = substr(v, 13)
      else if (v ~ /^-C./) d = substr(v, 3)
    }
    if (ex) chk_dir(d != "" ? d : CUR)
    return
  }
  if (cmd == "unzip") {
    d = ""
    for (j = k + 1; j <= n; j++) { v = W[L, j]; if (v == "-d") { d = W[L, j + 1]; j++ } else if (v ~ /^-d./) d = substr(v, 3) }
    chk_dir(d != "" ? d : CUR)
    return
  }
  all = inl("tee mv rm unlink rmdir truncate touch shred ed ex vi vim nano patch chmod chown chgrp", cmd)
  dest = inl("cp install ln rsync scp", cmd)
  if (cmd == "sed" || cmd == "gsed" || cmd == "perl") {
    for (j = k + 1; j <= n; j++) if (W[L, j] ~ /^-[A-Za-z]*i/ || index(W[L, j], "--in-place") == 1) hasi = 1
    if (hasi) all = 1
  }
  if (!all && !dest) return
  for (j = k + 1; j <= n; j++) {
    v = W[L, j]
    if (skipd) { skipd = 0; continue }
    if (v == "-t" || v == "--target-directory") { tdir = W[L, j + 1]; skipd = 1; continue }
    if (index(v, "--target-directory=") == 1) { tdir = substr(v, 20); continue }
    if (v ~ /^-[A-Za-z]*[rRa]/ || v == "--recursive" || v == "--archive") rec = 1
    if (substr(v, 1, 1) == "-" && v != "-") continue
    np++; MP[L, np] = v
  }
  if (tdir != "") chk_write(tdir, 0)
  if (cmd == "ln") {
    for (i = 1; i <= np && !blocked; i++) chk_dir(MP[L, i])
    return
  }
  if (cmd == "mv") {
    for (i = 1; i <= np && !blocked; i++) chk_dir(MP[L, i])
    if (np > 0 || tdir != "") destchk(L, np, tdir, cmd, rec)
    return
  }
  if (cmd == "rm" || cmd == "rmdir" || cmd == "unlink" || cmd == "shred") {
    for (i = 1; i <= np && !blocked; i++) chk_dir(MP[L, i])
    return
  }
  if (dest) { if (np > 0 || tdir != "") destchk(L, np, tdir, cmd, rec); return }
  for (i = 1; i <= np && !blocked; i++) chk_write(MP[L, i], (cmd == "tee" || cmd == "sed" || cmd == "gsed" || cmd == "perl" || cmd == "ed" || cmd == "ex" || cmd == "vi" || cmd == "vim" || cmd == "nano" || cmd == "patch"))
}

function hsubs(b, senv,   i, n, c, d, st) {
  # an unquoted heredoc delimiter: $(...) and backticks in the body run as commands
  n = length(b); i = 1
  while (i <= n && !blocked) {
    c = substr(b, i, 1)
    if (c == "$" && substr(b, i + 1, 1) == "(") {
      d = 1; i += 2; st = i
      while (i <= n && d > 0) { c = substr(b, i, 1); if (c == "(") d++; else if (c == ")") d--; i++ }
      analyze(substr(b, st, i - st - 1), senv)
    } else if (c == "`") {
      i++; st = i
      while (i <= n && substr(b, i, 1) != "`") i++
      analyze(substr(b, st, i - st), senv); i++
    } else i++
  }
}
function flush(L,   i, n, pipeo, hb, hx, hs) {
  endword(L)
  pipeo = pipeout[L]; hb = hbody[L]; hx = hexp[L]; hs = hsw[L]
  for (i = 1; i <= nr[L] && !blocked; i++) chk_redir(rop[L, i], rtg[L, i])
  n = nw[L]
  if (hx != "" && !blocked) hsubs(hx, senvL[L])
  if (n > 0 && !blocked) {
    # the previous command of the pipeline printed a secret variable: this one must be a known consumer
    if (pendsec[L]) { pendsec[L] = 0; if (!consumer_ok(L, n)) block("secret", "une variable secrète est envoyée dans un tube vers une commande qui peut l'afficher") }
    # here-string: a secret variable (any variable inside kit secrets run) goes to stdin
    if (hs != "" && !blocked && index(hs, "$") > 0 && (senvL[L] || secretvar(hs)) && !consumer_ok(L, n)) block("secret", "here-string avec une variable secrète")
    if (!blocked) runcmd(L, 1, n, senvL[L], pipeo, hb)
  }
  reset(L)
}

# --- tool paths (Read, Edit, Write, Grep...) --------------------------------------------------------------------
function paths(buf,   n, a, i, kind, v, p, restr) {
  n = split(buf, a, "\n")
  restr = 0
  for (i = 1; i <= n; i++) {
    kind = substr(a[i], 1, 1); v = substr(a[i], 3)
    if (kind == "G" && v != "" && restrictive_glob(v)) restr = 1
    if (kind == "T" && v != "") restr = 1
  }
  for (i = 1; i <= n && !blocked; i++) {
    if (a[i] == "") continue
    kind = substr(a[i], 1, 1); v = substr(a[i], 3)
    if (v == "") continue
    if (kind == "T") continue
    if (kind == "G") {
      DOTOK = 1
      if (glob_secret_br(v) || sp(norm(v))) block("secret", "motif de fichiers de secrets (" v ")")
      DOTOK = 0
      continue
    }
    p = norm(v)
    if (kind == "D") {
      if (!restr && above_store(p)) block("secret", "recherche récursive depuis un dossier qui contient des identifiants (" v ")")
      continue
    }
    if (sp(p)) block("secret", "accès à un fichier de secrets (" why ": " v ")")
    else if (kind == "W" && protected(p)) block("config", "écriture dans la configuration ou le code gérés par kit (" v ")")
  }
}

BEGIN {
  HOME = ENVIRON["GUARD_HOME"]; if (HOME == "") HOME = "/nonexistent-home"
  sub(/\/+$/, "", HOME)
  CUR = ENVIRON["GUARD_CWD"]; if (CUR == "") CUR = "/unknown-cwd"
  KC = ENVIRON["GUARD_KITCFG"]; if (KC == "") KC = HOME "/.config/claude-kit"
  CH = ENVIRON["GUARD_CLAUDE"]; if (CH == "") CH = HOME "/.claude"
  XD = ENVIRON["GUARD_XDG"]; if (XD == "") XD = HOME "/.config"
  KH = ENVIRON["GUARD_KITHOME"]
  PATHRE = "^[]A-Za-z0-9_.~$/@:+=%*?,{}[-]+$"
  CODEJUNK = "[^]A-Za-z0-9_.~$/@:+=%*?,{}[-]"
  NAMERE = "(token|secret|passw|credential|passphrase|api_?key|private_?key|access_?key|bearer|cookie|(^|_)(pat|key|auth|authorization)(_|$)|_key|key_)"
  ENVDUMP = "(os[.]environ([^]A-Za-z_.[]|$)|os[.]environ[.](items|copy|keys|values)|process[.]env([^]A-Za-z_.[]|$)|process[[]['\"]?env|ENV[.](to_h|each|to_a)|[%]ENV)"
  ENVACCESS = "(environ|getenv|process[.]env|[$]env[{]|env[[])"
  RES["{"] = 1; RES["}"] = 1; RES["!"] = 1; RES["if"] = 1; RES["then"] = 1; RES["else"] = 1; RES["elif"] = 1
  RES["do"] = 1; RES["while"] = 1; RES["until"] = 1; RES["time"] = 1; RES["coproc"] = 1
  TEXTS = "echo printf true false : sleep cd pushd popd mkdir rmdir rm touch chmod chown chgrp ls stat test [ [[ which type realpath readlink dirname basename du df file wc id date pwd unset alias export set read local declare typeset readonly let ln mktemp kill ps sync wait hash umask shred trap return exit"
  NOCHK = "ssh-add ssh-keygen ssh-copy-id"
  SSHLIKE = "ssh scp sftp rsync ssh-keyscan"
  SSHARGS = " -i -F -o -E -S -J -l -p -P -c -L -R -D -W -I -b "
  PATS = "grep egrep fgrep rg ag ack sed gsed awk gawk mawk nawk jq yq gojq jaq"
  COPYS = "cp mv install rsync scp"
  nsamp = split(".env .env.local .env.production .envrc id_rsa id_ed25519 id_ecdsa a.pem a.key a.p12 .netrc .npmrc app.env prod.env terraform.tfstate secrets.tfvars .claude.json", samp, " ")
  ndirs = split("/.aws/ /.gnupg/ /.kube/ /.config/gh/ /.config/sops/ /.config/age/ /.age/ /.config/gcloud/ /.config/rclone/ /.config/doctl/ /.config/hcloud/ /.wrangler/ /.config/.wrangler/ /.cloudflared/ /.config/claude-kit/secrets/ /.local/share/keyrings/ /var/lib/tailscale/ /.docker/ /etc/shadow/ /etc/gshadow/", dirs, " ")
  # credential stores, as directories (for "is this search root above a store?")
  nsroots = 0
  for (i = 1; i <= ndirs; i++) {
    d = dirs[i]; sub(/\/$/, "", d)
    sroots[++nsroots] = (substr(d, 1, 2) == "/." ? HOME d : d)
  }
  sroots[++nsroots] = HOME "/.ssh"
  nroots = 0
  roots[++nroots] = tolower(HOME "/.config/claude-kit"); roots[++nroots] = tolower(KC); roots[++nroots] = tolower(XD "/claude-kit")
  roots[++nroots] = "/etc/claude-code"
  nfiles = 0
  files[++nfiles] = tolower(HOME "/.claude/settings.json"); files[++nfiles] = tolower(HOME "/.claude/settings.local.json")
  files[++nfiles] = tolower(CH "/settings.json"); files[++nfiles] = tolower(CH "/settings.local.json")
  # the installed kit: its scripts (hooks are symlinks into them) and the settings that kit sync reads
  nprot = 0
  if (KH != "") { roots[++nroots] = tolower(KH "/scripts"); protpre[++nprot] = tolower(KH "/global/settings") }
}
{ buf = buf $0 "\n" }
END {
  if (ENVIRON["GUARD_MODE"] == "bash") analyze(buf, 0)
  else paths(buf)
  if (blocked) printf "BLOCK\t%s\t%s\n", bkind, breason
  for (i = 1; i <= ncommit; i++) printf "COMMIT\t%s\n", cdir[i]
  print "OK"
}
AWK_END

case $tool in
  Bash)
    mode=bash; payload=$cmd
    ((${#cmd} <= 262144)) || block system "commande de plus de 256 Ko : analyse impossible"
    ;;
  Read | Edit | Write | MultiEdit | NotebookEdit | Grep)
    mode=paths; payload=""
    kind=R
    case $tool in Edit | Write | MultiEdit | NotebookEdit) kind=W ;; esac
    if [[ -n $path ]]; then
      payload="$kind"$'\t'"$path"
      # A symlink to a secret is a secret, and so is a file under a symlinked directory: resolve both (the extra forks
      # only happen for symlinks and existing directories).
      p=$path
      # shellcheck disable=SC2088  # a literal "~/" prefix is what we test
      case $p in "~/"*) p=$HOME/${p#"~/"} ;; /*) ;; *) p=${cwd:-.}/$p ;; esac
      n=0
      while [[ -L $p && $n -lt 4 ]]; do
        t=$(readlink "$p") || break
        case $t in /*) p=$t ;; *) p=${p%/*}/$t ;; esac
        payload="$payload"$'\n'"$kind"$'\t'"$p"
        n=$((n + 1))
      done
      d=${p%/*}
      if [[ -n $d && -d $d ]]; then
        rd=$(cd -P -- "$d" 2>/dev/null && pwd -P) || rd=""
        if [[ -n $rd && $rd != "$d" ]]; then payload="$payload"$'\n'"$kind"$'\t'"$rd/${p##*/}"; fi
      fi
    fi
    if [[ -n $glob ]]; then payload="${payload:+$payload$'\n'}G"$'\t'"$glob"; fi
    if [[ -n $gtype ]]; then payload="${payload:+$payload$'\n'}T"$'\t'"$gtype"; fi
    if [[ $tool == Grep ]]; then
      # the search root (the path, or the working directory): a recursive search from $HOME or / reads credential stores
      payload="${payload:+$payload$'\n'}D"$'\t'"${path:-$cwd}"
    fi
    [[ -n $payload ]] || exit 0
    ;;
  *) exit 0 ;;
esac
[[ -n $payload ]] || exit 0

# The installed kit = the real path of this hook (hooks are symlinks into $KIT_HOME/scripts/hooks): its code and its
# settings are protected from agent writes. A hook run from elsewhere (a copy) protects nothing extra.
self=${BASH_SOURCE[0]}
n=0
while [[ -L $self && $n -lt 6 ]]; do
  t=$(readlink "$self") || break
  case $t in /*) self=$t ;; *) self=${self%/*}/$t ;; esac
  n=$((n + 1))
done
kit_home=""
if [[ $self == */scripts/hooks/guard-secrets.sh && -f $self ]]; then
  kit_home=$(cd -P -- "${self%/scripts/hooks/*}" 2>/dev/null && pwd -P) || kit_home=""
fi

res=$(printf '%s' "$payload" | GUARD_MODE=$mode GUARD_HOME=${HOME:-} GUARD_CWD=$cwd GUARD_KITCFG=${KIT_CONFIG:-} \
  GUARD_CLAUDE=${CLAUDE_HOME:-} GUARD_XDG=${XDG_CONFIG_HOME:-} GUARD_KITHOME=$kit_home awk "$AWK_PROG" 2>/dev/null) || res=""

# Fail closed: the analysis always ends with an "OK" line.
[[ $res == *$'\n'OK || $res == OK ]] || block system "l'analyse n'a pas abouti (awk absent ou en échec)"

# BLOCK<TAB>kind<TAB>reason, then one COMMIT<TAB>dir line per `git commit`.
line=${res%%$'\n'*}
if [[ $line == BLOCK$'\t'* ]]; then
  rest=${line#BLOCK$'\t'}
  block "${rest%%$'\t'*}" "${rest#*$'\t'}"
fi

# A commit is refused when its diff contains a known key or token pattern (in the repository the commit targets:
# `git -C dir` or the directory of a preceding `cd`).
if [[ $res == *COMMIT$'\t'* ]]; then
  while IFS= read -r line; do
    [[ $line == COMMIT$'\t'* ]] || continue
    cdir=${line#COMMIT$'\t'}
    [[ -d $cdir ]] || cdir=.
    diff=$( { git -C "$cdir" diff --cached -U0; git -C "$cdir" diff -U0; } 2>/dev/null | grep -E '^\+[^+]' || true)
    if grep -Eq 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AGE-SECRET-KEY-1[A-Z0-9]{50,}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|sk-[A-Za-z0-9_-]{32,}|xox[baprs]-[A-Za-z0-9-]{10,}' <<<"$diff"; then
      block secret "le diff contient ce qui ressemble à une clé ou un jeton"
    fi
  done <<<"$res"
fi

exit 0
