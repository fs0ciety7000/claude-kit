# Environnement cloud « fs0 » (proposition)

Environnement claude.ai/code recommandé pour les sessions qui utilisent le kit. **À créer par le propriétaire**
(menu de l'environnement → New environment) : rien ici n'est créé automatiquement. Une seule source de vérité pour
le script de démarrage : la section « claude.ai/code » du `README.md`.

## Réglages

| Réglage | Valeur |
|---|---|
| Nom | `fs0` |
| Script de démarrage | celui du `README.md` (clone du kit puis `install.sh --cloud`) |
| Accès réseau | niveau par défaut (registres de paquets et GitHub déjà autorisés) + les hôtes ci-dessous |
| Jetons | version **dev**, portée minimale, jamais ceux de prod |

## Hôtes à ajouter

Seulement ceux que les commandes du kit appellent et que la liste par défaut ne couvre pas (relevés dans
`scripts/`) :

| Hôte | Utilisé par |
|---|---|
| `api.cloudflare.com` | `kit api cloudflare` (zones, DNS) |
| `skills.sh` | `kit equip search` (`npx skills find`) |
| hôte de l'instance Coolify (valeur de `COOLIFY_BASE_URL`, hors dépôt) | `kit api coolify` |

`github.com`, `api.github.com` et `raw.githubusercontent.com` (clone du kit, `npx skills add`, `kit add-agent`)
ainsi que les registres npm, Go, crates et PyPI font partie de la liste par défaut. Les CI Forgejo
(`templates/ci/`) tournent sur le runner, pas dans la session : rien à ajouter pour elles.

## Variables (noms seulement)

| Nom | Rôle |
|---|---|
| `COOLIFY_BASE_URL` | URL de l'instance Coolify (`kit api coolify`) |
| `COOLIFY_ACCESS_TOKEN` | jeton Coolify dev ; de préférence en secret réseau (injecté par le proxy, absent du conteneur) |
| `CLOUDFLARE_API_TOKEN` | jeton Cloudflare à portée minimale ; secret réseau de préférence |
| `CLOUDFLARE_ACCOUNT_ID` | identifiant de compte pour les chemins `{account_id}` de `kit api cloudflare` |
| `KIT_LOCAL_ENVIRONMENT` | phrases `autoMode.environment` propres au propriétaire (voir `kit overlay env`) |
| `KIT_DOCKERD` | `0` pour ne pas démarrer le démon Docker en session (hook `kit-dockerd`) |

`CLAUDE_CODE_REMOTE=true` est posé par la plateforme : `kit new` s'en sert (avec le profil `cloud` d'`install.sh`) pour
passer en mode cloud. Pas de `GITHUB_TOKEN` dans cet environnement : l'accès GitHub de la session est limité aux
dépôts attachés, et la création d'un dépôt se fait depuis le poste (`kit new` affiche la commande exacte).
