# Réglages gérés : programme jq utilisé par apply_managed_settings (scripts/lib.sh).
#
# Clés gérées : permissions.allow|ask|deny|defaultMode, hooks, autoMode.*. Rien d'autre n'est lu ni écrit.
#
#   --arg mode project|build|merge
#   project : entrée = un réglage ; sortie = ses seules clés gérées.
#   build   : entrée = tableau de réglages (jq -s), du moins prioritaire au plus prioritaire ; sortie = leur
#             fusion (listes en union dédoublonnée, ordre gardé ; defaultMode : le dernier présent gagne). C'est K.
#   merge   : fusion à trois points. --slurpfile c|k|l|r (réglage actuel, du kit pour ce poste, registre = K de la
#             dernière fois, règles retirées par le kit), --argjson prefixes (préfixes ancrés du dossier des hooks du
#             kit), names (noms des scripts de hooks du kit) et yes (accepte un defaultMode plus permissif). Sortie : {new, changes}.
#
# Règles :
#   - allow, autoMode.environment, autoMode.allow : nouvelle liste = K puis U (ajouts de l'utilisateur = C moins L),
#     dédoublonnée, ordre gardé.
#   - deny, ask, autoMode.soft_deny, autoMode.hard_deny (les listes qui restreignent) : jamais retirées
#     automatiquement. Nouvelle liste = K puis C, sans les seules entrées listées dans le fichier des règles retirées
#     (r). Une entrée de l'utilisateur identique à une règle du kit survit donc au retrait de cette règle du kit.
#   - hooks : une entrée de C est au kit si sa commande est exactement <préfixe ancré><script du kit> ET si le même
#     couple (matcher, commande) figure dans K ou L. Seules ces entrées sont retirées (le groupe disparaît s'il ne
#     reste rien) : un hook de l'utilisateur dans le même groupe, un script du kit réutilisé avec un autre matcher, un
#     chemin hors préfixe ancré ou un script inconnu restent.

def arr: if type == "array" then . else [] end;
def dedup: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
def minus($b): map(select(. as $x | any($b[]; . == $x) | not));

def project:
  {permissions: ((.permissions // {}) | {allow, ask, deny, defaultMode} | with_entries(select(.value != null))),
   hooks: .hooks,
   autoMode: .autoMode}
  | with_entries(select(.value != null and .value != {}));

def build:
  reduce (.[] | project) as $f ({};
    reduce ("allow", "ask", "deny") as $k (.;
      .permissions[$k] = (((.permissions[$k] // []) + ($f.permissions[$k] | arr)) | dedup))
    | (if $f.permissions.defaultMode then .permissions.defaultMode = $f.permissions.defaultMode else . end)
    | reduce (($f.hooks // {}) | keys_unsorted[]) as $e (.;
        .hooks[$e] = (((.hooks[$e] // []) + ($f.hooks[$e] | arr)) | dedup))
    | reduce (($f.autoMode // {}) | keys_unsorted[]) as $k (.;
        .autoMode[$k] = (((.autoMode[$k] // []) + ($f.autoMode[$k] | arr)) | dedup)));

# --- hooks ---------------------------------------------------------------------------------------------------------

def kitcmd($pre; $names):
  . as $c
  | type == "string"
    and any($pre[]; . as $p | ($c | startswith($p)) and (($c[($p | length):]) as $b | any($names[]; . == $b)));

def allcmds($o): [($o.hooks // {}) | .[] | arr | .[] | .hooks | arr | .[] | (.command? // empty) | select(type == "string")];

# Noms des scripts du kit : ceux de la liste fournie, plus ceux que K et L référencent sous un préfixe ancré.
def kitnames($k; $l; $pre; $names):
  $names
  + [(allcmds($k) + allcmds($l))[] | . as $c | select(any($pre[]; . as $p | $c | startswith($p))) | split("/") | last];

# Couples [matcher, commande] des hooks du kit d'un événement (K et L).
def kitpairs($groups; $pre; $names):
  [$groups[]? | (.matcher // null) as $m | (.hooks | arr | .[]) | (.command // null) as $c
   | select($c | kitcmd($pre; $names)) | [$m, $c]];

def strip_owned($pairs; $pre; $names):
  . as $g
  | ($g.matcher // null) as $m
  | if ($g.hooks | type) != "array" or ($g.hooks | length) == 0 then $g
    else
      ($g | .hooks |= map(select(
         (. as $h | ($h.command // null) as $c
          | (($c | kitcmd($pre; $names)) and any($pairs[]; . == [$m, $c]))) | not)))
      | if (.hooks | length) == 0 then empty else . end
    end;

# --- fusion --------------------------------------------------------------------------------------------------------

# Nouvelle liste (allow, environment…) : K, puis les ajouts de l'utilisateur (C moins L).
def three($kk; $ll; $cc): ($kk + ($cc | minus($ll))) | dedup;
# Nouvelle liste (deny, ask…) : K, puis tout C sauf les règles explicitement retirées.
def keepuser($kk; $cc; $rr): ($kk + ($cc | minus($rr))) | dedup;

# Rang de permissivité d'un defaultMode (plus grand = plus permissif) : un passage à un rang plus élevé est refusé sans yes.
def rank: {"plan": 0, "default": 1, "acceptEdits": 2, "auto": 3, "bypassPermissions": 4}[.] // 9;

def restrictive: . == "soft_deny" or . == "hard_deny";

def merge($c; $k; $l; $r; $pre; $names0; $yes):
  kitnames($k; $l; $pre; $names0) as $names
  | $c
  | reduce ("allow", "ask", "deny") as $key (.;
      .permissions[$key] =
        (if $key == "allow"
         then three(($k.permissions[$key] | arr); ($l.permissions[$key] | arr); ($c.permissions[$key] | arr))
         else keepuser(($k.permissions[$key] | arr); ($c.permissions[$key] | arr); ($r.permissions[$key] | arr)) end))
  | (if $k.permissions.defaultMode == null then .
     elif ($yes | not) and $c.permissions.defaultMode != null
          and ($k.permissions.defaultMode | rank) > ($c.permissions.defaultMode | rank) then .
     else .permissions.defaultMode = $k.permissions.defaultMode end)
  | reduce ((($k.hooks // {}) + ($c.hooks // {})) | keys_unsorted[]) as $e (.;
      kitpairs(($k.hooks[$e] | arr) + ($l.hooks[$e] | arr); $pre; $names) as $pairs
      | ($c.hooks[$e] | arr | [.[] | strip_owned($pairs; $pre; $names)]) as $cu
      | .hooks[$e] = three(($k.hooks[$e] | arr); ($l.hooks[$e] | arr); $cu))
  | (if .hooks == null then . else .hooks |= with_entries(select(.value | length > 0)) end)
  | (if .hooks == {} then del(.hooks) else . end)
  | reduce ((($k.autoMode // {}) + ($c.autoMode // {}) + ($l.autoMode // {})) | keys_unsorted[]) as $key (.;
      (if ($key | restrictive)
       then keepuser(($k.autoMode[$key] | arr); ($c.autoMode[$key] | arr); ($r.autoMode[$key] | arr))
       else three(($k.autoMode[$key] | arr); ($l.autoMode[$key] | arr); ($c.autoMode[$key] | arr)) end) as $v
      | if ($v | length) == 0 and ($c.autoMode[$key] == null) then . else .autoMode[$key] = $v end);

def changes($c; $new):
  def chg($path):
    ($c | getpath($path) | arr) as $a
    | ($new | getpath($path) | arr) as $b
    | {name: ($path | join(".")), added: ($b | minus($a)), removed: ($a | minus($b)),
       duplicates: (($a | length) - ($a | dedup | length))}
    | select((.added | length) + (.removed | length) + .duplicates > 0);
  ([["permissions", "allow"], ["permissions", "ask"], ["permissions", "deny"]]
   + ((($c.hooks // {}) + ($new.hooks // {})) | keys_unsorted | map(["hooks", .]))
   + ((($c.autoMode // {}) + ($new.autoMode // {})) | keys_unsorted | map(["autoMode", .])))
  | map(chg(.))
  + (if ($new.permissions.defaultMode) != ($c.permissions.defaultMode)
     then [{name: "permissions.defaultMode", added: [$new.permissions.defaultMode],
            removed: ([$c.permissions.defaultMode] | map(select(. != null))), duplicates: 0}]
     else [] end);

# $ARGS.named : les arguments absents selon le mode ne provoquent pas d'erreur de compilation.
$ARGS.named as $a
| if $a.mode == "project" then project
  elif $a.mode == "build" then build
  else
    ($a.c[0]) as $c
    | merge($c; $a.k[0]; ($a.l[0] // {}); ($a.r[0] // {}); ($a.prefixes // []); ($a.names // []); ($a.yes // false)) as $new
    | {new: $new, changes: changes($c; $new)}
  end
