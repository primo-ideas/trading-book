# Trading Book

[English](README.md)

Addon World of Warcraft (Retail, 12.1.5) qui garde la trace de vos enchères et de votre stock, avec des statistiques.

État : premier jet. La logique est testée hors du jeu, **mais l'addon n'a pas encore tourné dans le client** : voir [À vérifier en jeu](#à-vérifier-en-jeu).

## Installation

```powershell
.\install.ps1
```

Le script copie dans `Interface\AddOns\TradingBook` le fichier `TradingBook.toc` et les fichiers qu'il liste, rien d'autre : ni les tests, ni ce README, ni le dépôt Git. Après une modification du code, relancez-le, puis faites `/reload` en jeu ; si la liste de fichiers du `.toc` a changé, redémarrez WoW, qui ne la lit qu'au lancement. Il ne demande pas de droits d'administrateur si votre compte peut écrire dans le dossier de WoW, ce qui est le cas par défaut.

| Option | Effet |
| --- | --- |
| `-Clean` | Supprime aussi les données sauvegardées de Trading Book (historique, stock, or) sur tous les comptes, sauvegarde `.bak` comprise. C'est irréversible : une confirmation est demandée, et WoW doit être fermé. |
| `-WowPath <dossier>` | Indique le dossier de WoW, celui qui contient `_retail_`, s'il n'est pas à l'emplacement standard. |
| `-WhatIf` | Montre ce qui serait fait, sans rien modifier. |

Le dossier installé est remplacé à chaque fois : n'y gardez rien. Les données sauvegardées sont ailleurs et ne sont touchées que par `-Clean`. Si un dossier `TradingBook` existant ne vient pas de ce script (autre addon, lien, copie de travail), le script s'arrête sans y toucher.

## Utilisation

`/tradingbook` ouvre la fenêtre, tout comme l'icône de la minicarte et l'entrée Trading Book du menu des addons. `/tradingbook auctions`, `stock`, `stats` et `gold` ouvrent directement un onglet.

L'icône de la minicarte se déplace en la faisant glisser, et `/tradingbook minimap` la masque ou la réaffiche.

| Onglet | Contenu |
| --- | --- |
| **Enchères** | Historique des ventes, achats, mises en vente, expirations et annulations, ainsi que les enchères en cours. |
| **Stock** | Objets échangeables, filtrables par emplacement (sacs, banque perso, stock commun, courrier, hôtel des ventes), avec évolution sur 7 jours et valeur estimée. |
| **Stats** | Bénéfice, ventes, achats, frais, taux de vente, valeur du stock et or, sur 7, 30 ou 90 jours ou depuis le début, avec le résultat par jour et par objet. |
| **Or** | Courbe de l'or, évolution, moyenne par jour, meilleur et pire jour, record, part des enchères dans les gains et répartition par détenteur. |

Les données couvrent tout le compte. Le menu en haut à droite restreint l'affichage à un personnage, y compris un autre que celui connecté. Le « stock commun » désigne la banque de bataillon : comme elle n'appartient à personne, son filtre l'affiche quel que soit le personnage choisi.

Une évolution d'or ne compte que ce qui a changé depuis que Trading Book suit le détenteur : la première connexion d'un personnage n'est pas un gain, et transférer de l'or vers le stock commun ne change pas le total. « Hors enchères » est la différence entre l'évolution de l'or et le résultat des enchères ; une vente pas encore retirée du courrier peut donc y décaler temporairement le partage.

La valeur du stock vient d'Auctionator s'il est installé, sinon de la moyenne de vos ventes sur 90 jours. Un objet sans prix connu compte pour zéro.

## Langues

L'addon suit la langue du client : anglais, français, allemand, espagnol (Espagne et Mexique), italien, portugais du Brésil, russe, coréen, chinois simplifié et traditionnel. L'ordre du jour et du mois dans les dates suit aussi la langue. Les mots de la commande `/tradingbook` restent en anglais.

Les textes anglais servent de clés et de repli, chaque autre langue a son fichier dans `Locales/`. Pour ajouter un texte, écrivez `L["Texte en anglais"]` dans le code et ajoutez sa traduction à tous ces fichiers : les tests échouent s'il en manque une ou si une traduction ne sert plus.

## Comment les données sont collectées

| Donnée | Source | Moment |
| --- | --- | --- |
| Mise en vente | Appels `PostItem` et `PostCommodity` | Confirmée par `AUCTION_HOUSE_AUCTION_CREATED` |
| Annulation | Appel `CancelAuction` | Confirmée par `AUCTION_CANCELED` |
| Vente, achat, expiration | Courrier de l'hôtel des ventes et sa facture | Au retrait du courrier |
| Enchères en cours | `GetOwnedAuctions` | À l'ouverture de l'hôtel des ventes |
| Stock | Sacs, banque, banque de bataillon, courrier | À chaque changement ; banques seulement quand elles sont ouvertes |

Bénéfice net = ventes - achats - frais, où frais = commission + dépôts non remboursés + coûts d'annulation. Ce calcul suit l'argent réellement encaissé et dépensé : le dépôt payé à la mise en vente revient avec le paiement de la vente.

## Limites connues

- Une vente n'apparaît qu'une fois son courrier retiré. Elle est toutefois datée d'après le temps restant du courrier, donc les statistiques par jour restent justes.
- La banque et la banque de bataillon affichent leur contenu à la dernière visite.
- Le stock en courrier ne voit que les 50 premiers courriers chargés par le client.
- Les objets sont regroupés par identifiant : les variantes d'un même objet (niveau d'objet) et les mascottes en cage sont confondues.
- Après un envoi multiple interrompu, la quantité mise en vente reste celle demandée au départ.
- Le coût d'achat d'un objet fabriqué n'est pas connu : le bénéfice ne compte que les achats à l'hôtel des ventes.
- L'icône suit un cercle autour de la minicarte : sur une minicarte carrée (ElvUI, par exemple), elle ne va pas jusque dans les coins.

## À vérifier en jeu

Le faux client des tests ne dessine rien et reflète ma lecture de l'API. Ces points restent donc à confirmer :

1. **Interface** : fenêtre et portrait, onglets, menu des personnages, colonnes, défilement, graphiques, icône de la minicarte (apparence, déplacement, position retrouvée à la reconnexion). Les marges sont vérifiées par les tests, mais avec une largeur de texte estimée.
2. **Vente** : la commission et le dépôt affichés correspondent à la facture du courrier. C'est le point le plus incertain : si la facture n'est pas lisible au retrait, le montant retombe sur l'argent du courrier et la commission à zéro.
3. **Achat** : le prix est renseigné après le retrait du courrier.
4. **Mise en vente** : une seule ligne avec le bon dépôt, y compris avec Auctionator et en envoi multiple.
5. **Annulation** : le coût est renseigné.
6. **Banque de bataillon** : son contenu et son or apparaissent à l'ouverture de la banque.
7. **Courrier plein** : un retrait échoué sur sacs pleins, puis réussi, ne compte qu'une fois.
8. **Traductions** : aucune n'a été relue par un locuteur natif ni vue dans le client. Le vocabulaire du jeu (banque de bataillon, dépôt, hôtel des ventes) est à comparer à celui de chaque version, et les textes longs à vérifier à l'écran, surtout en allemand et en russe.

Pour inspecter les données en jeu : `/dump TradingBook.db.ledger[#TradingBook.db.ledger]`.

## Tests

Les tests tournent sur Lua 5.1, la version utilisée par WoW, contre un faux client strict où toute globale ou méthode inconnue provoque une erreur. Les tests de mise en page s'exécutent dans chaque langue.

```powershell
pip install lupa
python tests/run.py
```

## Publication sur CurseForge

`.pkgmeta` décrit le paquet : un dossier `TradingBook` contenant le `.toc` et les fichiers qu'il liste, comme `install.ps1`.

À faire une fois :

1. Créez le projet sur CurseForge et relevez son identifiant, dans « About This Project » sur sa page d'aperçu.
2. Créez un jeton sur [la page des jetons d'API](https://www.curseforge.com/account/api-tokens).
3. Sur GitHub, dans les réglages du dépôt, ajoutez un webhook d'URL `https://www.curseforge.com/api/projects/{projectID}/package?token={token}`, en laissant les autres réglages par défaut. Ce jeton est un secret : il ne doit jamais entrer dans le dépôt.

Ensuite, chaque version est un tag :

```powershell
git tag v0.1.0
git push origin v0.1.0
```

Le nom du tag devient le numéro de version de l'addon. Un tag contenant `alpha` ou `beta` publie une version alpha ou bêta, sinon une version stable. Installé avec `install.ps1`, l'addon garde `@project-version@` comme numéro de version, que seul le paquet remplace.

## Structure

| Fichier | Rôle |
| --- | --- |
| `Core.lua` | Événements, données sauvegardées, formatage, commande `/tradingbook` |
| `Ledger.lua` | Historique des opérations |
| `Auctions.lua` | Mises en vente, annulations, enchères en cours |
| `Mail.lua` | Ventes, achats et expirations lus dans le courrier |
| `Stockpile.lua` | Stock et son historique |
| `Gold.lua` | Historique de l'or par détenteur et son analyse |
| `Stats.lua` | Calculs statistiques et estimation des prix |
| `Locales.lua`, `Locales/` | Choix de la langue et traductions (l'anglais sert de clé et de repli) |
| `UI/` | Fenêtre, tableaux et onglets |
| `tests/` | Faux client et tests |
| `install.ps1`, `.pkgmeta` | Installation locale et paquet CurseForge |
