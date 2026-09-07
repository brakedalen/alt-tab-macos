# Test AltTab dev på macOS 26

Utgaven bygger på AltTab 11.5.0. Den heter **AltTab dev**, har bundle-ID
`no.brakedalen.AltTab-dev` og versjon **11.5.1**. Se
[byggeveiledningen](development-build.md) for Xcode og stabil signering, og
[undersøkelsen med kilder](performance-research-2026-09-05.md) for grunnlaget.

## Hva som er endret

- Bakgrunnsopptak er avslått som standard. Fokusbytte respekterer nå dette valget.
  Vinduslisten oppdateres fortsatt med hendelser. Miniatyrbilder oppdateres når
  vindusvelgeren åpnes; ved første åpning kan et appikon vises mens bildet kommer.
- Maksimalt to skjermbildeforespørsler behandles samtidig. En plass frigjøres først
  når svaret er mottatt og behandlet, ikke allerede når forespørselen er sendt.
  Tallet to er et utgangspunkt for testing, ikke en målt optimalverdi.
- Forespørsler om vindusmetadata samles når flere bilder mangler samtidig.
  Foreldet arbeid forkastes, og svar fra en avsluttet visningsøkt kan ikke fylle
  bildebufferen til en ny økt. Synlige miniatyrbilder prioriteres.
- Første bildeoppdatering ved åpning begrenses til vinduer som vises i listen.
  Fullskjermruten beholdes fordi upstream har dokumentert en feil ved alternativet
  på inaktive Spaces. Fullskjerm, minimering og Spaces må derfor testes særskilt.
- macOS 26 er minste systemversjon. Innlogging bruker `SMAppService.mainApp`.
  Oppstart ved innlogging, offisielle oppdateringer og krasjinnsending er av for
  testutgaven. Lisenslogikken er beholdt, med eget lagringsområde.
- Kontroll av Tilgjengelighet går etter oppstart over til den tiltenkte
  reservekontrollen hvert 60. sekund. En feil i rekkefølgen holdt den på fem
  sekunder. Den hyppigere kontrollen mens tillatelsesvinduet er åpent beholdes.

Dette dokumenterer mindre arbeid og strengere grenser i koden. Det er ennå ikke
et måleresultat som viser hvor mye CPU, strøm eller WindowServer-minne du sparer.

## Første oppstart

1. Åpne `alt-tab-macos.xcodeproj` og velg skjemaet **AltTab dev**. Dette kjører
   optimalisert Release uten debugger eller debuglogg. Debug-skjemaet er for
   feilsøking, ikke en rettferdig ytelsessammenligning med offisiell Release.
2. Bruk en vedvarende signeringsidentitet som beskrevet i byggeveiledningen.
   Ad-hoc-signering er nok for kompilering, men macOS kan kreve nye tillatelser
   etter ombygging. Hold sertifikat, bundle-ID og appens plassering stabile.
3. Avslutt offisiell AltTab før du starter testutgaven. Begge kan være installert,
   men globale hurtigtaster og macOS sin native Command-Tab-tilstand er felles.
4. Gi **AltTab dev** egne tillatelser til Tilgjengelighet og Skjermopptak når
   macOS ber om det. Den offisielle utgavens tillatelser skal ikke endres.
5. Still inn den samme miniatyrvisningen og filtreringen som du bruker til vanlig.
   Dine skjermbilder viser synlige Spaces og skjuling av minimerte, skjulte,
   fullskjerm- og vindusløse apper. Testutgaven starter med egne innstillinger;
   de offisielle innstillingene eller lisensdataene kopieres ikke automatisk.

Ved import av eksporterte innstillinger: slå bakgrunnsopptak av igjen for den
første testen. En import kan ellers gjeninnføre «på» fra den offisielle utgaven.

## Kontroller at funksjonene virker

| Scenario | Hva du kontrollerer |
|---|---|
| Åpne, bla og slipp hurtigtasten | Riktig vindu får fokus, og miniatyrbildene kommer uten lang kø. |
| Åpne/lukke veldig raskt flere ganger | Ny økt får bilder; ingen gamle forhåndsvisninger kommer tilbake. |
| Dra størrelse, åpne/lukke vinduer mens listen vises | Listen og bildene følger vinduene. |
| Dra en fil eller lenke til en miniatyr | Innholdet åpnes i riktig app, og et sent svar lukker ikke en ny visningsøkt. |
| Åpne en app uten vinduer fra listen | Appen aktiveres og kan åpne sitt vindu. |
| Finder-faner og bytte av aktiv fane | Riktig vindu/fane vises. Uten bakgrunnsopptak kan et tidligere usett vindu vise appikon først. |
| Minimer/gjenopprett et vindu | Ingen fastlåst eller permanent liten miniatyr etter animasjonen. |
| Fullskjerm på aktiv og annen Space | Test med fullskjermvinduer satt til «vis», og gå tilbake til normal filtrering etterpå. |
| Koble til/fra ekstern skjerm | Riktig plassering og størrelse på vindusvelger og bilder. |
| Lås opp og våkn fra hvile | Hurtigtastene virker, og nye bilder kan hentes. |
| Bakgrunnsopptak av/på/av | Av skal hindre nye bakgrunnsforespørsler. Allerede påbegynte OS-kall må få avslutte. |
| Eventuell stor forhåndsvisning | Test separat fra miniatyrvisningen du vanligvis bruker. |

## Mål samme arbeidsmengde

Test med samme vinduer, skjermoppløsning, skalering og oppdateringsfrekvens. Hold
video, skjermdeling, nettleseraktivitet og andre vindusverktøy så like som mulig.
La Xcode-bygg bli ferdig og maskinen roe seg før du måler. Ikke ha debug-/QA-vinduer
stående åpne. En kort måling mens Codex kompilerer er ingen god baseline.

Sammenlign separate perioder med **offisiell AltTab**, **ingen AltTab**, og
**AltTab dev**. Ta først en rolig periode, deretter samme serie med for eksempel
30 åpninger og vindusbytter, og så en ny rolig periode. Gjenta i motsatt rekkefølge
for å redusere effekten av varm cache og tidligere systemtilstand. Sammenlign
også offisiell utgave med bakgrunnsopptak av; ellers blandes innstillingsendring
og kodeendring sammen. Test innebygd og ekstern skjerm i separate serier.

Fra repomappen kan du lagre ett minutts måling uten å endre eller avslutte apper:

```sh
mkdir -p ai/output
bash scripts/measure_resources.sh 31 2 > ai/output/resources-dev.txt
```

Bytt filnavn for hver variant. Skriptet finner gjeldende prosess-ID-er og måler
AltTab, AltTab dev, WindowServer, Ice, replayd og systemstatusd når de kjører.
Første `top`-rad har ingen intervallbaseline for CPU; bruk de etterfølgende.
`MEM` er prosessens footprint, og skal ikke sammenlignes direkte med `ps` sitt
RSS-tall. Noter også minnepress, komprimert minne og swap fra Aktivitetsmonitor.

Ved feilsøking viser Debug-loggen antall sendte, fullførte, aktive og ventende
skjermbildeforespørsler når vindusvelgeren lukkes. Allerede sendte OS-kall kan
fortsatt være aktive da; senere svar skal frigjøre plassene. Disse tellerne
er for kontroll av køen. Bruk fortsatt Release for selve CPU-sammenligningen.

For en separat vindusoversikt, uten vindustitler eller bilder:

```sh
xcrun swift scripts/window_inventory.swift > ai/output/windows.txt
```

Antall vinduer er ikke en rangering av CPU-forbruk. `kCGWindowMemoryUsage` er
Apples estimat for vinduet og tilhørende strukturer; på denne maskinen var
verdiene for små til å forklare WindowServers totale minnebruk. Ikke bruk dem
som en fordeling av WindowServer-minne mellom apper.

En egen oversikt viser hvilke apper som har installert input-filtre (*event
taps*), uten å samle tastetrykk eller musehendelser:

```sh
xcrun swift scripts/event_tap_inventory.swift > ai/output/event-taps.txt
```

Forsinkelse i denne oversikten er ikke CPU eller skjermopptaksaktivitet. Apple
opplyser at selve metadataforespørselen nullstiller min-/maksstatistikken til
gjennomsnittsverdien. Bruk derfor ikke maksverdier fra ulike tidsperioder som
en direkte sammenligning.

Ved vedvarende problemer: bruk Instruments **Time Profiler** under selve
hendelsen, og kontroller systemprosessene på samme tidslinje. Bytt bare én
kandidat om gangen, for eksempel Ice eller en aktiv Edge-fane. En annen apps
egen CPU er ikke automatisk dens bidrag til WindowServer. Bruk en lengre økt
med like handlinger for å undersøke minnevekst; den første oppvarmingen av en
cache er ikke i seg selv en lekkasje.

## Når testen er ferdig

Avslutt AltTab dev og start den offisielle utgaven igjen om ønskelig. Siden
oppstart ved innlogging er av som standard, starter testutgaven ikke automatisk.
Hvis du aktiverte den, slå den av i testutgaven eller i macOS Innloggingsobjekter.
Ingen globale `tccutil reset`-kommandoer er nødvendige.
