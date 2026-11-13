#!/usr/bin/env bash
# PreToolUse hook of Claude Code: blocks real access to secret files and values, and agent writes to kit-managed
# settings. It judges the FILES a command touches, never the words it mentions: a jq path such as `.environment`, a
# grep pattern, a commit message, a PR body or a JSON rule that names `.env` or `*.pem` is not an access.
#
# Input: JSON on stdin. Output: exit 2 + message on stderr = action blocked.
# Budget: one hook process per tool call (hooks_per_tool_call.Bash = 1): one jq and one awk, nothing else, except
# `git diff` when the command commits.
#
# Blocked:
#   - Read/Edit/Write/MultiEdit/NotebookEdit/Grep on a secret file: .env and .env.* (not .env.example, .sample,
#     .template, .tpl, .dist), .envrc, private keys (id_* without .pub, *.pem, *.key, .p12...), ~/.ssh private
#     material (not *.pub, config, known_hosts), ~/.aws, ~/.gnupg, ~/.kube, ~/.config/gh, ~/.config/sops, token
#     stores (.netrc, .npmrc, .pypirc, ~/.docker/config.json, ~/.claude.json...), /proc/*/environ.
#   - Bash: the same files as OPERANDS of a reader (cat, head, cp, base64, git add, curl -d @file...) or as the target
#     of a redirection; sops decrypt/exec-env, age decrypt, `kit secrets edit`, `gh auth token`; dumps of the
#     environment (printenv, env, set, export -p, jq env, os.environ dumps); echo/printf of a variable named like a
#     secret (not when piped); anything printing the environment inside `kit secrets run`; a commit whose diff
#     contains a key or token pattern.
#   - Write tools and Bash (cp, mv, tee, rm, touch, sed -i, redirections, dd of=, curl -o...) on
#     ~/.config/claude-kit/** (settings.local.json, environment.local.txt, autoupdate.pin, registry...) and on
#     ~/.claude/settings.json: only `kit sync`, `kit overlay` and `kit autoupdate` write them.
# It does not block: a command that only names such a file in quoted text, a pattern or a filter; `cp .env.example
# .env` (the destination of a copy is not read); `ls`, `test -f`, `rm` and `chmod` on a secret (metadata only).
#
# It is a guard rail, not a guarantee: a shell can always hide a path (variable, encoding, interpreter). The real
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
  "x" + (.tool_input.command // "")' 2>/dev/null) || exit 0

tool=${parsed%%$'\n'*}; parsed=${parsed#*$'\n'}; tool=${tool#x}
cwd=${parsed%%$'\n'*}; parsed=${parsed#*$'\n'}; cwd=${cwd#x}
path=${parsed%%$'\n'*}; parsed=${parsed#*$'\n'}; path=${path#x}
glob=${parsed%%$'\n'*}; cmd=${parsed#*$'\n'}; glob=${glob#x}; cmd=${cmd#x}

block() { # kind reason
  {
    echo "Bloqué par claude-kit : $2"
    if [[ $1 == config ]]; then
      echo "Ces réglages sont écrits par kit seulement : kit sync, kit overlay, kit autoupdate (ou à la main par l'utilisateur)."
    else
      echo "Pour qu'une commande reçoive des secrets sans que tu les voies : kit secrets run -- <commande>"
    fi
  } >&2
  exit 2
}

# The awk program (portable: POSIX awk, no gawk extension; read -d '' needs no fork).
read -r -d '' AWK_PROG <<'AWK_END'
function lowercase(s) { return tolower(s) }
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
function glob2re(g,   i, c, r) {
  r = "^"
  for (i = 1; i <= length(g); i++) {
    c = substr(g, i, 1)
    if (c == "*") r = r ".*"
    else if (c == "?") r = r "."
    else if (index("\\.+(){}|^$[]", c) > 0) r = r "\\" c
    else r = r c
  }
  return r "$"
}
# Can this glob (basename) match a secret file name? (shell semantics: a leading dot must be literal)
function glob_secret(b,   lit, re, k, s) {
  lit = b; gsub(/[*?]/, "", lit)
  if (length(lit) < 2) return 0
  re = glob2re(b)
  for (k = 1; k <= nsamp; k++) {
    s = samp[k]
    if (substr(s, 1, 1) == "." && substr(b, 1, 1) != ".") continue
    if (s ~ re) return 1
  }
  return 0
}
# A normalised absolute path that names secret material? Sets why.
function sp(p,   b, lb, d, n, parts, suf, i) {
  why = ""
  if (p == "") return 0
  b = bn(p); lb = tolower(b)
  if (b ~ /[*?]/ && glob_secret(b)) { why = "motif de fichiers de secrets"; return 1 }
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
  if (lb ~ /^id_[a-z0-9_.-]+$/ && lb !~ /\.pub$/) { why = "clé privée"; return 1 }
  if (lb ~ /\.(pem|key|p12|pfx|p8|jks|keystore|ppk|kdbx|agekey)$/) { why = "clé ou certificat privé"; return 1 }
  d = p "/"
  if (index(d, "/.ssh/") > 0) {
    if (lb ~ /\.pub$/ || p ~ /\/\.ssh\/(config|known_hosts|known_hosts\.old)$/) return 0
    why = "matériel privé de ~/.ssh"; return 1
  }
  for (i = 1; i <= ndirs; i++) if (index(d, dirs[i]) > 0) { why = "magasin d'identifiants (" dirs[i] ")"; return 1 }
  if (p ~ /^\/proc\/[^\/]+\/environ$/) { why = "environnement d'un processus"; return 1 }
  if (index(p, "/.terraform.d/credentials") > 0) { why = "magasin d'identifiants"; return 1 }
  if (p ~ /^\/etc\/ssh\/ssh_host_.*_key$/) { why = "clé d'hôte SSH"; return 1 }
  return 0
}
function protected(p,   i) {
  for (i = 1; i <= nroots; i++) if (p == roots[i] || index(p, roots[i] "/") == 1) return 1
  for (i = 1; i <= nfiles; i++) if (p == files[i]) return 1
  return 0
}
function clean(w) { gsub(/\001/, "$", w); return w }
# A word that looks like a path (no spaces, quotes, parentheses...) and has no unknown expansion.
function pathlike(w) { return index(w, "\002") == 0 && w ~ PATHRE }

# Read check of one operand word: the word itself and the tails after "=", "@" and ":" (--x=file, @file, host:file, rev:file).
function chk_read(w,   c, i, ch, cand, nb, alt, j, pre, inner, suf, m, inb, p) {
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
  if (protected(p)) { block("config", "écriture dans la configuration gérée par kit (" w ")"); return }
  if (strict && sp(p)) block("secret", "écriture dans un fichier de secrets (" why ": " w ")")
}
function chk_redir(op, t) {
  if (blocked || t == "") return
  if (op == "<") chk_read(t)
  else if (index(op, ">") > 0) { chk_write(t, 1); if (op == "<>") chk_read(t) }
}

# --- tokenizer -----------------------------------------------------------------------------------------------
function newlevel(L, kind, senv) {
  nw[L] = 0; nr[L] = 0; nh[L] = 0; pend[L] = ""; hbody[L] = ""; hexp[L] = ""; inw[L] = 0; wq[L] = 0; wd[L] = ""; pipeout[L] = 0
  kindl[L] = kind; par[L] = 0; senvL[L] = senv
}
function reset(L) { nw[L] = 0; nr[L] = 0; pend[L] = ""; hbody[L] = ""; hexp[L] = ""; pipeout[L] = 0 }
function addc(L, ch) { inw[L] = 1; wd[L] = wd[L] ch }
function endword(L,   x, qd) {
  if (!inw[L]) return
  inw[L] = 0
  x = wd[L]; wd[L] = ""; qd = wq[L]; wq[L] = 0
  if (pend[L] != "") {
    if (pend[L] == "<<" || pend[L] == "<<-") { nh[L]++; hd[L, nh[L]] = x; hdt[L, nh[L]] = (pend[L] == "<<-"); hdq[L, nh[L]] = qd }
    else if (pend[L] != "<<<") { nr[L]++; rop[L, nr[L]] = pend[L]; rtg[L, nr[L]] = x }
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
  if (dep > 4 || blocked) return
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
function secretvar(v,   lv2, rest) {
  lv2 = tolower(v)
  while (match(lv2, SECVAR)) {
    rest = substr(lv2, RSTART + RLENGTH)
    if (substr(rest, 1, 1) == "}" || substr(rest, 1, 2) != ":+" && substr(rest, 1, 1) != "+") return 1
    lv2 = rest
  }
  return 0
}
function code_scan(str,   t, n, a, i, p) {
  if (str ~ ENVDUMP) { block("secret", "affichage de tout l'environnement depuis un interpréteur"); return }
  gsub(CODEJUNK, " ", str)
  n = split(str, a, " ")
  for (i = 1; i <= n && !blocked; i++) {
    t = a[i]
    if (index(t, "/") > 0 || substr(t, 1, 1) == "." || substr(t, 1, 1) == "~") chk_read(t)
  }
}
function jq_env(f) { return f ~ /(^|[^A-Za-z0-9_.$])env([^A-Za-z0-9_]|$)/ || index(f, "$ENV") > 0 || index(f, "\001ENV") > 0 || index(f, "$__prog_args") > 0 }

function runcmd(L, k, n, senv, pipeo, hb,   w, cmd, j, v, s, na, ja, sub1, np, last, tdir, hasi, first, patdone, noopt, skipd, eq, haspat, nsk) {
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
    if (cmd == "xargs") { k = skipo(L, k + 1, n, " -n -I -L -P -d -E -s -a -J "); continue }
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
      if (j < n) runcmd(L, j + 1, n, 1, pipeo, hb)
      return
    }
  }
  # nested shells and eval: the string is a command line
  if (inl("bash sh zsh dash ksh", cmd)) {
    for (j = k + 1; j <= n; j++) {
      v = W[L, j]
      if (v == "--") break
      if (v ~ /^-[A-Za-z]*c[A-Za-z]*$/) { if (j < n) analyze(W[L, j + 1], senv); return }
      if (substr(v, 1, 1) != "-") break
    }
    if (hb != "") analyze(hb, senv)
  }
  if (cmd == "eval") {
    s = ""
    for (j = k + 1; j <= n; j++) s = s " " W[L, j]
    analyze(s, senv)
    return
  }

  # environment dumps
  if (cmd == "printenv") {
    if (na == 0) { block("secret", "lecture de l'environnement du processus (printenv)"); return }
    for (j = k + 1; j <= n; j++) if (tolower(W[L, j]) ~ SECNAME) { block("secret", "affichage d'une variable secrète (printenv)"); return }
    return
  }
  if (cmd == "set" && na == 0) { block("secret", "lecture de l'environnement du shell (set)"); return }
  if (cmd == "export" && (na == 0 || W[L, k + 1] == "-p")) { block("secret", "lecture de l'environnement du shell (export)"); return }
  if (cmd == "declare" || cmd == "typeset") {
    np = 0; ja = 0
    for (j = k + 1; j <= n; j++) { if (substr(W[L, j], 1, 1) == "-") { if (W[L, j] ~ /[xp]/) ja = 1 } else np++ }
    if (np == 0 && (na == 0 || ja)) { block("secret", "lecture de l'environnement du shell (declare)"); return }
  }
  # echo/printf of a variable named like a secret (a pipe into another command is a use, not a print)
  if (cmd == "echo" || cmd == "printf" || cmd == "print") {
    for (j = k + 1; j <= n; j++) {
      v = W[L, j]
      if (index(v, "$") == 0) continue
      if (senv) { block("secret", "affichage d'une variable d'environnement injectée par kit secrets run"); return }
      if (!pipeo && secretvar(v)) { block("secret", "affichage d'une variable secrète (" v ")"); return }
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

  # interpreters: -c / -e strings are code; scan them for secret paths and environment dumps
  if (inl("python python3 node nodejs ruby perl php deno bun lua", cmd) || cmd ~ /^python[0-9.]+$/) {
    for (j = k + 1; j < n; j++) {
      v = W[L, j]
      if (v ~ /^-[A-Za-z]*[ceEpr][A-Za-z]*$/) { code_scan(clean(W[L, j + 1])); break }
    }
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
  if (cmd == "find") {
    hasi = 0
    for (j = k + 1; j <= n; j++) if (inl("-exec -execdir -ok -okdir", W[L, j])) hasi = 1
    if (!hasi) return
  }
  if (inl(PATS, cmd)) { patscan(L, k, n, cmd); return }
  if (inl(COPYS, cmd)) { copyscan(L, k, n); return }
  defscan(L, k, n, cmd)
}

function defscan(L, k, n, cmd,   j, v, skipd, eq, sshl) {
  sshl = inl(SSHLIKE, cmd)
  skipd = 0
  for (j = k + 1; j <= n && !blocked; j++) {
    v = W[L, j]
    if (skipd) { skipd = 0; continue }
    if (sshl && index(SSHARGS, " " v " ") > 0) { skipd = 1; continue }
    if (v == "--") continue
    if (substr(v, 1, 1) == "-" && v != "-") { eq = index(v, "="); if (eq > 0) chk_read(substr(v, eq + 1)); continue }
    chk_read(v)
  }
}
function copyscan(L, k, n,   j, v, np, tdir, skipd, i) {
  np = 0; tdir = ""; skipd = 0
  for (j = k + 1; j <= n; j++) {
    v = W[L, j]
    if (skipd) { skipd = 0; continue }
    if (v == "-t" || v == "--target-directory") { tdir = W[L, j + 1]; skipd = 1; continue }
    if (index(SSHARGS " -e --rsh --exclude --include --filter ", " " v " ") > 0) { skipd = 1; continue }
    if (substr(v, 1, 1) == "-" && v != "-") continue
    np++; PP[L, np] = v
  }
  # the destination of a copy is not read (cp .env.example .env): only the sources are checked
  for (i = 1; i <= (tdir != "" ? np : np - 1) && !blocked; i++) chk_read(PP[L, i])
}
function patscan(L, k, n, cmd,   j, v, have, patdone, noopt, isjq) {
  have = 0; isjq = inl("jq yq gojq jaq", cmd)
  for (j = k + 1; j <= n; j++) if (inl("-e --regexp --expression -f --file --from-file", W[L, j])) have = 1
  patdone = have; noopt = 0
  for (j = k + 1; j <= n && !blocked; j++) {
    v = W[L, j]
    if (!noopt && v == "--") { noopt = 1; continue }
    if (!noopt && substr(v, 1, 1) == "-" && v != "-") {
      if (isjq && (v == "--arg" || v == "--argjson")) { j += 2; continue }
      if (isjq && (v == "--slurpfile" || v == "--rawfile" || v == "--argfile")) { chk_read(W[L, j + 2]); j += 2; continue }
      if (isjq && (v == "--args" || v == "--jsonargs")) break
      if (v == "-e" || v == "--regexp" || v == "--expression") { if (isjq && jq_env(W[L, j + 1])) block("secret", "jq lit l'environnement (env)"); j++; continue }
      if (v == "-f" || v == "--file" || v == "--from-file") { chk_read(W[L, j + 1]); j++; continue }
      if (inl("awk gawk mawk nawk", cmd)) { if (v == "-v" || v == "-F") { j++; continue } }
      else if (index(" -A -B -C -m -D -j -g --glob -t -T --type --max-count --after-context --before-context --context ", " " v " ") > 0 || (v == "-d" && !isjq)) { j++; continue }
      continue
    }
    if (!patdone) { patdone = 1; if (isjq && jq_env(v)) block("secret", "jq lit l'environnement (env)"); continue }
    chk_read(v)
  }
}
function gitchk(L, k, n,   j, v, sub1, patdone, afterdd) {
  j = k + 1; sub1 = ""
  while (j <= n) {
    v = W[L, j]
    if (v == "-C" || v == "-c" || v == "--git-dir" || v == "--work-tree" || v == "--namespace") { j += 2; continue }
    if (substr(v, 1, 1) == "-") { j++; continue }
    sub1 = v; break
  }
  if (sub1 == "commit") commit = 1
  if (!inl("show diff log blame cat-file grep add commit annotate whatchanged format-patch archive", sub1)) return
  if (sub1 == "log" || sub1 == "whatchanged") {
    # the log prints file contents only with a patch option
    patdone = 0
    for (j = j + 1; j <= n; j++) if (W[L, j] == "-p" || W[L, j] == "--patch" || W[L, j] == "-u" || W[L, j] == "--cc" || W[L, j] == "-c") patdone = 1
    if (!patdone) return
    j = k + 1
    while (j <= n && W[L, j] != "log" && W[L, j] != "whatchanged") j++
  }
  patdone = (sub1 != "grep"); afterdd = 0
  for (j = j + 1; j <= n && !blocked; j++) {
    v = W[L, j]
    if (!afterdd && v == "--") { afterdd = 1; continue }
    if (!afterdd && substr(v, 1, 1) == "-" && v != "-") {
      if (inl("-m -am --message -F --file -S -G -e --grep --author --format --pretty -n --date --since --until -U --abbrev", v)) j++
      continue
    }
    if (!patdone) { patdone = 1; continue }
    chk_read(v)
  }
}
function mutchk(L, k, n, cmd,   j, v, np, i, hasi, tdir, all, dest, skipd) {
  np = 0; tdir = ""; hasi = 0; skipd = 0
  if (cmd == "curl" || cmd == "wget") {
    for (j = k + 1; j <= n; j++) {
      v = W[L, j]
      if (v == "-o" || v == "--output" || v == "-O" && cmd == "wget" || v == "--output-document" || v == "-P" || v == "--directory-prefix") { chk_write(W[L, j + 1], 0); j++ }
      else if (index(v, "--output=") == 1) chk_write(substr(v, 10), 0)
      else if (index(v, "--output-document=") == 1) chk_write(substr(v, 19), 0)
    }
    return
  }
  if (cmd == "dd") {
    for (j = k + 1; j <= n; j++) if (index(W[L, j], "of=") == 1) chk_write(substr(W[L, j], 4), 1)
    return
  }
  all = inl("tee mv rm unlink rmdir truncate touch shred ed ex vi vim nano", cmd)
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
    if (substr(v, 1, 1) == "-" && v != "-") continue
    np++; MP[L, np] = v
  }
  if (tdir != "") chk_write(tdir, 0)
  if (all) { for (i = 1; i <= np && !blocked; i++) chk_write(MP[L, i], (cmd == "tee" || cmd == "sed" || cmd == "gsed" || cmd == "perl" || cmd == "ed" || cmd == "ex" || cmd == "vi" || cmd == "vim" || cmd == "nano")) }
  else if (np > 0) chk_write(MP[L, np], 0)
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
function flush(L,   i, n, pipeo, hb, hx) {
  endword(L)
  pipeo = pipeout[L]; hb = hbody[L]; hx = hexp[L]
  for (i = 1; i <= nr[L] && !blocked; i++) chk_redir(rop[L, i], rtg[L, i])
  n = nw[L]
  if (hx != "" && !blocked) hsubs(hx, senvL[L])
  if (n > 0 && !blocked) runcmd(L, 1, n, senvL[L], pipeo, hb)
  reset(L)
}

# --- tool paths (Read, Edit, Write, Grep...) --------------------------------------------------------------------
function paths(buf,   n, a, i, kind, v, p) {
  n = split(buf, a, "\n")
  for (i = 1; i <= n && !blocked; i++) {
    if (a[i] == "") continue
    kind = substr(a[i], 1, 1); v = substr(a[i], 3)
    if (v == "") continue
    p = norm(v)
    if (kind == "G") {
      if (sp(p) || glob_secret(bn(v))) block("secret", "motif de fichiers de secrets (" v ")")
      continue
    }
    if (sp(p)) block("secret", "accès à un fichier de secrets (" why ": " v ")")
    else if (kind == "W" && protected(p)) block("config", "écriture dans la configuration gérée par kit (" v ")")
  }
}

BEGIN {
  HOME = ENVIRON["GUARD_HOME"]; if (HOME == "") HOME = "/nonexistent-home"
  sub(/\/+$/, "", HOME)
  CUR = ENVIRON["GUARD_CWD"]; if (CUR == "") CUR = "/unknown-cwd"
  KC = ENVIRON["GUARD_KITCFG"]; if (KC == "") KC = HOME "/.config/claude-kit"
  CH = ENVIRON["GUARD_CLAUDE"]; if (CH == "") CH = HOME "/.claude"
  XD = ENVIRON["GUARD_XDG"]; if (XD == "") XD = HOME "/.config"
  PATHRE = "^[A-Za-z0-9_.~$/@:+=%*?,{}-]+$"
  CODEJUNK = "[^A-Za-z0-9_.~$/@:+=%*?,{}-]"
  SECVAR = "[$][{]?[a-z0-9_]*(token|secret|passw|api_?key|private_?key|access_?key|credential|passphrase)[a-z0-9_]*"
  SECNAME = "(token|secret|passw|api_?key|private_?key|access_?key|credential|passphrase)"
  ENVDUMP = "(os[.]environ([^]A-Za-z_.[]|$)|os[.]environ[.](items|copy|keys|values)|process[.]env([^]A-Za-z_.[]|$)|ENV[.](to_h|each|to_a)|[%]ENV)"
  RES["{"] = 1; RES["}"] = 1; RES["!"] = 1; RES["if"] = 1; RES["then"] = 1; RES["else"] = 1; RES["elif"] = 1
  RES["do"] = 1; RES["while"] = 1; RES["until"] = 1; RES["time"] = 1
  TEXTS = "echo printf true false : sleep cd pushd popd mkdir rmdir rm touch chmod chown chgrp ls stat test [ [[ which type realpath readlink dirname basename du df file wc id date pwd unset alias export set read local declare typeset readonly let ln mktemp kill ps sync wait hash umask shred trap return exit"
  NOCHK = "ssh-add ssh-keygen ssh-copy-id"
  SSHLIKE = "ssh scp sftp rsync ssh-keyscan"
  SSHARGS = " -i -F -o -E -S -J -l -p -P -c -L -R -D -W -I -b "
  PATS = "grep egrep fgrep rg ag ack sed gsed awk gawk mawk nawk jq yq gojq jaq"
  COPYS = "cp mv install rsync scp"
  nsamp = split(".env .env.local .env.production .envrc id_rsa id_ed25519 id_ecdsa a.pem a.key a.p12 .netrc .npmrc", samp, " ")
  ndirs = split("/.aws/ /.gnupg/ /.kube/ /.config/gh/ /.config/sops/ /.config/age/ /.age/ /.config/gcloud/ /.config/rclone/ /.config/doctl/ /.config/hcloud/ /.wrangler/ /.config/.wrangler/ /.cloudflared/ /.config/claude-kit/secrets/ /.local/share/keyrings/ /var/lib/tailscale/ /.docker/config.json/ /etc/shadow/ /etc/gshadow/", dirs, " ")
  roots[1] = HOME "/.config/claude-kit"; roots[2] = KC; roots[3] = XD "/claude-kit"; roots[4] = "/etc/claude-code"; nroots = 4
  files[1] = HOME "/.claude/settings.json"; files[2] = HOME "/.claude/settings.local.json"
  files[3] = CH "/settings.json"; files[4] = CH "/settings.local.json"; nfiles = 4
}
{ buf = buf $0 "\n" }
END {
  if (ENVIRON["GUARD_MODE"] == "bash") analyze(buf, 0)
  else paths(buf)
  if (blocked) printf "BLOCK\t%s\t%s\n", bkind, breason
  if (commit) print "COMMIT"
}
AWK_END

case $tool in
  Bash) mode=bash; payload=$cmd ;;
  Read | Edit | Write | MultiEdit | NotebookEdit | Grep)
    mode=paths; payload=""
    kind=R
    case $tool in Edit | Write | MultiEdit | NotebookEdit) kind=W ;; esac
    if [[ -n $path ]]; then
      payload="$kind"$'\t'"$path"
      # A symlink to a secret is a secret: resolve one level (rare, so the extra fork only happens then).
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
    fi
    if [[ -n $glob ]]; then payload="${payload:+$payload$'\n'}G"$'\t'"$glob"; fi
    [[ -n $payload ]] || exit 0
    ;;
  *) exit 0 ;;
esac
[[ -n $payload ]] || exit 0

res=$(printf '%s' "$payload" | GUARD_MODE=$mode GUARD_HOME=${HOME:-} GUARD_CWD=$cwd GUARD_KITCFG=${KIT_CONFIG:-} \
  GUARD_CLAUDE=${CLAUDE_HOME:-} GUARD_XDG=${XDG_CONFIG_HOME:-} awk "$AWK_PROG" 2>/dev/null) || res=""

# BLOCK<TAB>kind<TAB>reason, then COMMIT when the command runs `git commit`.
line=${res%%$'\n'*}
if [[ $line == BLOCK$'\t'* ]]; then
  rest=${line#BLOCK$'\t'}
  block "${rest%%$'\t'*}" "${rest#*$'\t'}"
fi

# A commit is refused when its diff contains a known key or token pattern.
if [[ $res == *COMMIT* ]]; then
  diff=$( { git diff --cached -U0; git diff -U0; } 2>/dev/null | grep -E '^\+[^+]' || true)
  if grep -Eq 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AGE-SECRET-KEY-1[A-Z0-9]{50,}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|sk-[A-Za-z0-9_-]{32,}|xox[baprs]-[A-Za-z0-9-]{10,}' <<<"$diff"; then
    block secret "le diff contient ce qui ressemble à une clé ou un jeton"
  fi
fi

exit 0
