TPV Widget 2.1 - overlay for TrainingPeaks Virtual
===================================================
English | Svenska | Français

ENGLISH
-------
An always-on-top widget shown over the TrainingPeaks Virtual (TPV) window: W'bal gauge, power,
draft and braking, corner advice, profile of the road ahead, next climb, graphs.
It never touches the game: it only reads the data TPV publishes.

Nothing to install
1. Recommended: before unzipping, right-click the .zip file > Properties > tick "Unblock" > OK.
   Otherwise Windows may ask for confirmation on the first start.
2. Unzip the TPVWidget folder anywhere (for example in Documents).
3. Double-click "Start TPV Widget.cmd". A black window opens for a second, then the widget appears.
   For a shortcut: right-click "Start TPV Widget.cmd" > Send to > Desktop.
Settings, learned corners and learned route profiles stay in this folder.
Update: offered at start. When a newer version is published on GitHub (github.com/TPVwidgethud/tpv-widget),
"Start TPV Widget.cmd" asks whether to install it: Yes installs it and keeps your settings, No starts
the version you have. To never be asked: create an empty file named no-update.txt in this folder.
Remove: close the widget (☰ > Close widget) and delete the folder.

Use
- Start the widget preferably before TPV.
- ☰ button at the top right of the widget: tabs DISPLAY (profiles and displayed items), LAYOUT,
  RIDER (FTP, W', CP: click a value to type it) and OTHER. A profile (Race, Climb, Training, Stream,
  Minimal) keeps its own displayed items, layout and position; changes are saved in the selected one.
- Edit layout: drag blocks, - / + badge on the block under the mouse = size of that block only
  (50 to 300 %, click the % = back to 100 %), double-click = full row, right-click a gauge or graph = two on one line,
  braking banner = drag to place it, - / + buttons on it = size, edges = resize. Esc when done.
- Shortcuts: Ctrl+Alt+F8 layout | Ctrl+Alt+F9 show/hide | Ctrl+Alt+F10 quit.
- WIND gauge: you seen from above, heading up; the arrows blow from where the wind comes from.
  Red = against you, yellow = from the side, green = pushing you. Next to it: HEADWIND,
  CROSSWIND FROM THE LEFT..., the speed, and the head/tail and side parts in km/h.
- TACTICS (race):
  ATTACK = a rider near you clearly faster than the riders around him,
  shown in its own block only. GROUP AHEAD / GROUP BEHIND = gap, size, and whether it is closing
  (green) or opening (orange), with the time to catch them. AT THE FRONT = time pulling with
  no draft in a group (orange after 30 s, ROTATE! after 1 min) and the share of the ride in
  the wheels. TEAM = your teammates' gaps (from the team code in TPV).
- MUSIC block: title of the song playing and previous / play-pause / next buttons, for the music
  Windows controls (YouTube or YouTube Music in a browser, Spotify...). The buttons can be clicked
  during a ride without leaving the game. Also Ctrl+Alt+F1 previous | Ctrl+Alt+F2 play/pause |
  Ctrl+Alt+F3 next. "Song title" in the displayed items hides the title, for example on a stream.

Read automatically
- Your name, FTP, CP and W': from the TPV logs (Documents\TPVirtual\LogFiles).
  W'bal is only computed for your own rider.
  ☰ > FTP, W' (kJ) and CP (W'BAL): - / + forces your own value (shown in orange with SET), AUTO goes back
  to the TPV value.
- Ride data: Documents\TPVirtual\Broadcast.
- Route profiles: route files installed by TPV, matched from the GPS position.
  Event route: when the game has not installed it, the widget reads it when the event opens, from
  the public event page on tpvirtualhub.com (only the event and route names are used). It is not
  kept: it is deleted when the event ends.
  On other roads the widget learns the profile as you ride.

If the widget stays on "Waiting for game data" during a ride: check that the folder
Documents\TPVirtual\Broadcast holds a focus.json file that keeps updating.

SVENSKA
-------
En widget som alltid ligger överst, ovanpå fönstret för TrainingPeaks Virtual (TPV): W'bal-mätare,
effekt, draft och inbromsning, kurvråd, profil för vägen framåt, nästa backe, grafer.
Den rör aldrig spelet: den läser bara de data som TPV publicerar.

Inget att installera
1. Rekommenderas: högerklicka på .zip-filen innan du packar upp den > Egenskaper > kryssa i
   "Avblockera" > OK. Annars kan Windows be om en bekräftelse vid första starten.
2. Packa upp mappen TPVWidget var du vill (till exempel i Dokument).
3. Dubbelklicka på "Start TPV Widget.cmd". Ett svart fönster öppnas en sekund, sedan visas widgeten.
   För en genväg: högerklicka på "Start TPV Widget.cmd" > Skicka till > Skrivbord.
Inställningar, inlärda kurvor och inlärda vägprofiler sparas i den här mappen.
Uppdatering: erbjuds vid start. När en nyare version finns på GitHub (github.com/TPVwidgethud/tpv-widget)
frågar "Start TPV Widget.cmd" om den ska installeras: Ja installerar den och behåller dina inställningar,
Nej startar den version du har. För att aldrig bli tillfrågad: skapa en tom fil som heter no-update.txt här.
Borttagning: stäng widgeten (☰ > Close widget) och radera mappen.

Användning
- Starta helst widgeten före TPV.
- Knappen ☰ uppe till höger på widgeten: flikarna DISPLAY (profiler och visade delar), LAYOUT,
  RIDER (FTP, W', CP: klicka på ett värde för att skriva det) och OTHER. En profil (Race, Climb, Training,
  Stream, Minimal) har egna visade delar, layout och position; ändringar sparas i den valda profilen.
- Edit layout: dra blocken, märket - / + på blocket under musen = storlek på just det blocket
  (50 till 300 %, klick på % = tillbaka till 100 %), dubbelklick = hel rad, högerklick på en mätare eller graf = två på samma
  rad, bromsbanner = dra för att placera den, knapparna - / + på den = storlek, kanterna = ändra
  storlek. Esc när du är klar.
- Kortkommandon: Ctrl+Alt+F8 layout | Ctrl+Alt+F9 visa/dölj | Ctrl+Alt+F10 avsluta.
- Mätaren WIND: du sedd ovanifrån, på väg uppåt; pilarna blåser från det håll vinden kommer ifrån.
  Rött = emot dig, gult = från sidan, grönt = skjuter på dig. Bredvid: HEADWIND,
  CROSSWIND FROM THE LEFT..., hastigheten samt mot-/medvinds- och sidodelen i km/h.
- TAKTIK (lopp):
  ATTACK = en cyklist nära dig som är klart snabbare än cyklisterna runt honom,
  visas bara i sitt eget block. GROUP AHEAD / GROUP BEHIND = lucka, storlek och om den krymper
  (grönt) eller växer (orange), med tiden tills du hinner ikapp. AT THE FRONT = tid i täten
  utan draft i en grupp (orange efter 30 s, ROTATE! efter 1 min) och andelen av turen på
  hjul. TEAM = lagkamraternas luckor (från lagkoden i TPV).
- Blocket MUSIC: titeln på låten som spelas och knapparna föregående / spela-pausa / nästa, för
  musik som Windows styr (YouTube eller YouTube Music i en webbläsare, Spotify...). Knapparna går
  att klicka på under en tur utan att lämna spelet. Även Ctrl+Alt+F1 föregående |
  Ctrl+Alt+F2 spela/pausa | Ctrl+Alt+F3 nästa. "Song title" bland de visade delarna döljer titeln,
  till exempel under en stream.
Texterna i widgeten är på engelska.

Läses automatiskt
- Ditt namn, din FTP, CP och W': från TPV:s loggar (Documents\TPVirtual\LogFiles).
  W'bal beräknas bara för din egen cyklist.
  ☰ > FTP, W' (kJ) och CP (W'BAL): - / + tvingar ett eget värde (visas i orange med SET), AUTO går
  tillbaka till värdet från TPV.
- Åkdata: Documents\TPVirtual\Broadcast.
- Vägprofiler: ruttfiler som TPV har installerat, igenkända från GPS-positionen.
  Ett evenemangs rutt: om spelet inte har installerat den läser widgeten den när evenemanget
  öppnas, från evenemangets offentliga sida på tpvirtualhub.com (bara evenemangets och ruttens
  namn används). Den sparas inte: den raderas när evenemanget är slut.
  På andra vägar lär sig widgeten profilen medan du cyklar.

Om widgeten står kvar på "Waiting for game data" under en tur: kontrollera att mappen
Documents\TPVirtual\Broadcast innehåller en fil focus.json som uppdateras.

FRANÇAIS
--------
Un widget toujours au premier plan, affiché par-dessus la fenêtre de TrainingPeaks Virtual (TPV) :
jauge W'bal, puissance, draft et freinage, conseils de virage, profil de la route à venir,
prochaine montée, graphiques. Il ne touche pas au jeu : il lit seulement les données que TPV publie.

Rien à installer
1. Conseillé : avant de décompresser, clic droit sur le fichier .zip > Propriétés > cochez
   « Débloquer » > OK. Sinon Windows peut demander une confirmation au premier lancement.
2. Décompressez le dossier TPVWidget où vous voulez (par exemple dans Documents).
3. Double-cliquez sur « Start TPV Widget.cmd ». Une fenêtre noire s'ouvre une seconde, puis le
   widget apparaît.
   Pour un raccourci : clic droit sur « Start TPV Widget.cmd » > Envoyer vers > Bureau.
Réglages, virages appris et profils de route appris restent dans ce dossier.
Mise à jour : proposée au lancement. Quand une version plus récente est publiée sur GitHub
(github.com/TPVwidgethud/tpv-widget), « Start TPV Widget.cmd » demande s'il faut l'installer : Oui l'installe
et garde vos réglages, Non démarre la version actuelle. Pour ne plus être sollicité : créez un fichier vide
nommé no-update.txt dans ce dossier.
Suppression : quittez le widget (☰ > Close widget) et supprimez le dossier.

Utilisation
- Lancez le widget de préférence avant TPV.
- Bouton ☰ en haut à droite du widget : onglets DISPLAY (profils et éléments affichés), LAYOUT,
  RIDER (FTP, W', CP : cliquez sur une valeur pour la taper) et OTHER. Un profil (Race, Climb, Training,
  Stream, Minimal) garde ses éléments affichés, sa disposition et sa position ; les changements vont dans le profil choisi.
- Edit layout : glisser les blocs, badge - / + sur le bloc sous la souris = taille de ce bloc seul
  (50 à 300 %, clic sur le % = retour à 100 %), double-clic = ligne entière, clic droit sur une jauge ou un
  graphique = deux sur la même ligne, bandeau de freinage = glisser pour le placer, boutons - / +
  dessus = taille, bords = redimensionner. Échap pour terminer.
- Raccourcis : Ctrl+Alt+F8 mise en page | Ctrl+Alt+F9 afficher/masquer | Ctrl+Alt+F10 quitter.
- Jauge WIND : vous, vu de dessus, roulant vers le haut ; les flèches soufflent depuis l'endroit
  d'où vient le vent. Rouge = contre vous, jaune = de côté, vert = dans le dos. À côté : HEADWIND,
  CROSSWIND FROM THE LEFT..., la vitesse, et les parts de face/dos et de côté en km/h.
- TACTIQUE (course) :
  ATTACK = un coureur proche nettement plus rapide que ceux qui l'entourent,
  affiché seulement dans sa case. GROUP AHEAD / GROUP BEHIND = écart, taille, et s'il se réduit
  (vert) ou s'agrandit (orange), avec le temps pour revenir. AT THE FRONT = temps passé à rouler
  sans abri dans un groupe (orange après 30 s, ROTATE! après 1 min) et la part de la sortie dans
  les roues. TEAM = les écarts de vos équipiers (d'après le code d'équipe dans TPV).
- Bloc MUSIC : titre du morceau en cours et boutons précédent / lecture-pause / suivant, pour la
  musique que Windows pilote (YouTube ou YouTube Music dans un navigateur, Spotify...). Les boutons
  se cliquent en roulant sans quitter le jeu. Aussi Ctrl+Alt+F1 précédent | Ctrl+Alt+F2
  lecture/pause | Ctrl+Alt+F3 suivant. « Song title » dans les éléments affichés masque le titre,
  par exemple en stream.
Les textes du widget sont en anglais.

Ce qui est lu automatiquement
- Votre nom, votre FTP, votre CP et votre W' : dans les journaux de TPV (Documents\TPVirtual\LogFiles).
  Le W'bal n'est calculé que pour votre coureur.
  ☰ > FTP, W' (kJ) et CP (W'BAL) : - / + force votre propre valeur (affichée en orange avec SET), AUTO
  revient à la valeur de TPV.
- Les données de course : Documents\TPVirtual\Broadcast.
- Le profil des routes : fichiers de route installés par TPV, reconnus par la position GPS.
  Route d'un événement : si le jeu ne l'a pas installée, le widget la lit à l'ouverture de
  l'événement sur sa page publique tpvirtualhub.com (seuls les noms de l'événement et de la route
  sont utilisés). Elle n'est pas conservée : elle est effacée à la fin de l'événement.
  Sur les autres routes, le widget apprend le profil en roulant.

Si le widget reste sur « Waiting for game data » pendant une sortie : vérifiez que le dossier
Documents\TPVirtual\Broadcast contient un fichier focus.json qui se met à jour.
