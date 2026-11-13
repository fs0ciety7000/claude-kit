# Réglages gérés : programme jq utilisé par apply_managed_settings (scripts/lib.sh).
#
# Clés gérées : permissions.allow|ask|deny|defaultMode, hooks, autoMode.*. Rien d'autre n'est lu ni écrit.
#
#   --arg mode project|build|merge
#   project : entrée = un réglage ; sortie = ses seules clés gérées.
#   build   : entrée = tableau de réglages (jq -s), du moins prioritaire au plus prioritaire ; sortie = leur
#             fusion (listes en union dédoublonnée, ordre gardé ; defaultMode : le dernier présent gagne). C'est K.
#   merge   : fusion à trois points. --slurpfile c|k|l (réglage actuel, du kit pour ce poste, registre = K de la
#             dernière fois) et --arg kitdir (dossier des hooks du kit). Sortie : {new, changes}.
#             Par liste : nouvelle = K puis U (ajouts de l'utilisateur = C moins L), dédoublonnée, ordre gardé.
#             Hooks : un groupe de C dont une commande pointe dans le dossier des hooks du kit appartient
#             toujours au kit (il ne devient jamais un ajout utilisateur), ce qui retire les doublons.

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

def kitowned($kitdir):
  any((.hooks[]? | (.command? // empty) | select(type == "string"));
      contains("/claude-kit/hooks/") or contains($kitdir + "/"));

# Nouvelle liste : K, puis les ajouts de l'utilisateur (C moins L).
def three($kk; $ll; $cc): ($kk + ($cc | minus($ll))) | dedup;

def merge($c; $k; $l; $kitdir):
  $c
  | reduce ("allow", "ask", "deny") as $key (.;
      .permissions[$key] = three(($k.permissions[$key] | arr); ($l.permissions[$key] | arr); ($c.permissions[$key] | arr)))
  | (if $k.permissions.defaultMode then .permissions.defaultMode = $k.permissions.defaultMode else . end)
  | reduce ((($k.hooks // {}) + ($c.hooks // {})) | keys_unsorted[]) as $e (.;
      ($c.hooks[$e] | arr | map(select(kitowned($kitdir) | not))) as $cu
      | .hooks[$e] = three(($k.hooks[$e] | arr); ($l.hooks[$e] | arr); $cu))
  | (if .hooks == null then . else .hooks |= with_entries(select(.value | length > 0)) end)
  | (if .hooks == {} then del(.hooks) else . end)
  | reduce ((($k.autoMode // {}) + ($c.autoMode // {}) + ($l.autoMode // {})) | keys_unsorted[]) as $key (.;
      three(($k.autoMode[$key] | arr); ($l.autoMode[$key] | arr); ($c.autoMode[$key] | arr)) as $v
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
    ($a.c[0]) as $c | merge($c; $a.k[0]; ($a.l[0] // {}); $a.kitdir) as $new
    | {new: $new, changes: changes($c; $new)}
  end
