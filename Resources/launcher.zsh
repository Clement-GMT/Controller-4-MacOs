#!/bin/zsh
# Pont manettes pour Xbox One, SCUF Valor Pro et Joy-Con 2.
emulate -L zsh
setopt PIPE_FAIL

readonly driver_app='/Applications/OpenJoystickDriver.app'
readonly driver_executable="$driver_app/Contents/MacOS/OpenJoystickDriver"
readonly extension_id='com.openjoystickdriver.XboxUSBDevice'
session_dir=''
worker_pid=''
worker_executable=''
readonly resources=${0:A:h}

cleanup() {
    if [[ -n $session_dir ]]; then
        /bin/rm -rf -- "$session_dir"
    fi
}
trap cleanup EXIT
trap 'if [[ -n $worker_pid ]]; then
    kill -TERM "$worker_pid" 2>/dev/null
    wait "$worker_pid"
fi
exit 130' INT TERM

usb_tree() {
    /usr/sbin/ioreg -r -c IOUSBHostDevice -l -w0 -d 3
}

read_usb() {
    local snapshot
    snapshot=$(usb_tree | /usr/bin/awk -v extension="$extension_id" -v vid="$vendor_id" -v pid="$product_id" '
        function add_device() {
            if (vendor == vid && product == pid) {
                count++
                if (steam) steam_owned++
                if (dext) extension_owned++
            }
        }
        /^\+-o / { add_device(); vendor = product = steam = dext = 0; next }
        /^  \|   "idVendor" = / { vendor = $NF }
        /^  \|   "idProduct" = / { product = $NF }
        /"UsbExclusiveOwner"/ && /steam_osx/ { steam = 1 }
        /"IOUserServerName"/ && index($0, extension) { dext = 1 }
        END { add_device(); print count + 0, steam_owned + 0, extension_owned + 0 }
    ') || return 1
    read -r usb_count steam_owned extension_owned <<< "$snapshot"
}

list_system_extensions() {
    /usr/bin/systemextensionsctl list
}

read_extension() {
    local listing line
    if (( extension_owned )); then
        extension_state=active
    elif listing=$(list_system_extensions 2>/dev/null); then
        line=$(printf '%s\n' "$listing" | /usr/bin/awk -v id="$extension_id" 'index($0, id " (") { print; exit }')
        case $line in
            *'[activated enabled]'*) extension_state=active ;;
            *'waiting to uninstall on reboot'*) extension_state=pending ;;
            *) extension_state=inactive ;;
        esac
    else
        extension_state=unknown
    fi
}

refresh_state() {
    if ! read_usb; then
        print -u2 'Impossible de lire le registre USB de macOS.'
        return 1
    fi
    [[ $model == xbox ]] && read_extension
    return 0
}

diagnostic() {
    if [[ $model == joycon2 ]]; then
        joycon_diagnostic
        return $?
    fi
    refresh_state || return 1
    if (( usb_count )); then
        printf '%s (%s) détectée en USB (%d).\n' "$model_name" "$model_id" "$usb_count"
        if (( steam_owned )); then
            print 'Steam utilise la connexion USB de la manette.'
        elif (( extension_owned )); then
            print 'L’extension USB d’OpenJoystickDriver utilise la manette.'
        fi
    else
        print "$model_name ($model_id) introuvable dans le registre USB."
    fi
    case $extension_state in
        active) print 'Extension USB OpenJoystickDriver : active.' ;;
        inactive) print 'Extension USB OpenJoystickDriver : inactive ou absente.' ;;
        pending) print 'Extension USB OpenJoystickDriver : retrait en attente d’un redémarrage.' ;;
        unknown) print 'Extension USB OpenJoystickDriver : statut global indisponible.' ;;
    esac
    if /usr/bin/hidutil list --matching '{"VendorID":1118,"ProductID":2828}' 2>/dev/null | /usr/bin/awk '/Xbox Adaptive Controller/ { found=1 } END { exit !found }'; then
        print 'Manette Xbox Adaptive Controller visible dans macOS.'
    fi
    if /usr/bin/hidutil list --matching '{"VendorID":1118,"ProductID":2835}' 2>/dev/null | /usr/bin/awk '/0x45e[[:space:]]+0xb13/ && /Virtual/ { found=1 } END { exit !found }'; then
        print 'Manette Xbox virtuelle pour les applications macOS visible.'
    fi
    if [[ $model == scuf && -x $driver_executable ]] && init_cli; then
        local report publication
        report=$(run_ojd controller show "$model_id" --json --timeout 3 2>/dev/null)
        publication=$(print -r -- "$report" | /usr/bin/plutil -extract publication.state raw -o - - 2>/dev/null)
        case $publication in
            Published) print 'OpenJoystickDriver publie la SCUF sous une identité virtuelle.' ;;
            NotPublished) print 'Le pilote voit la SCUF. Appuie sur A ou bouge un stick pour envoyer des entrées.' ;;
            *) print 'La SCUF n’est pas encore visible dans le service OpenJoystickDriver.' ;;
        esac
    fi
}

init_cli() {
    if [[ ! -x $driver_executable ]]; then
        print -u2 'Installe et ouvre OpenJoystickDriver 0.6.0-alpha.2 dans Applications.'
        print -u2 'https://github.com/xsyetopz/OpenJoystickDriver/releases/tag/0.6.0-alpha.2'
        return 1
    fi
    if [[ -z $session_dir ]]; then
        session_dir=$(/usr/bin/mktemp -d -t pont-manettes-usb) || return 1
    fi
    if [[ ! -L $session_dir/ojd ]]; then
        /bin/ln -s "$driver_executable" "$session_dir/ojd" || return 1
    fi
}

run_ojd() {
    "$session_dir/ojd" "$@"
}

joycon_diagnostic() {
    init_cli || return 1
    local identity side report publication
    printf 'Bluetooth macOS : '
    /usr/sbin/system_profiler SPBluetoothDataType -detailLevel mini | /usr/bin/awk '
        /^[[:space:]]*State:/ { sub(/^[[:space:]]*State: /, ""); print; found=1; exit }
        END { if (!found) print "état indisponible" }
    '
    for identity in 057E:2067 057E:2066; do
        if [[ $identity == 057E:2067 ]]; then side=gauche; else side=droit; fi
        if report=$(run_ojd controller show "$identity" --json --timeout 3 2>/dev/null); then
            publication=$(print -r -- "$report" | /usr/bin/plutil -extract publication.state raw -o - - 2>/dev/null)
            if [[ $publication == Published ]]; then
                print "Joy-Con 2 $side ($identity) connecté et publié comme manette virtuelle."
            else
                print "Joy-Con 2 $side ($identity) connecté. Bouge son stick pour tester les entrées."
            fi
        else
            print "Joy-Con 2 $side ($identity) introuvable dans OpenJoystickDriver."
        fi
    done
}

await_controller() {
    refresh_state || return 1
    if (( ! usb_count )); then
        print -u2 "Branche la $model_name ($model_id) et autorise l’accessoire si macOS le demande."
        return 1
    fi
}

manual_extension_steps() {
    print -u2 'Dans Réglages Système → Général → Éléments d’ouverture et extensions → Pilotes, désactive XboxUSBDevice (OpenJoystickDriver).'
}

release_extension() {
    refresh_state || return 1
    case $extension_state in
        inactive) return 0 ;;
        pending)
            print -u2 'macOS attend un redémarrage pour terminer le retrait de l’extension. Relance ce programme après le redémarrage.'
            return 1 ;;
        unknown)
            manual_extension_steps
            print -u2 'macOS n’a pas communiqué l’état de l’extension. Vérifie qu’elle est inactive puis relance l’action.'
            return 1 ;;

    esac
    if ! init_cli; then
        manual_extension_steps
        return 1
    fi
    print 'Désactivation de l’extension USB Xbox d’OpenJoystickDriver…'
    if ! run_ojd transport-extension deactivate; then
        manual_extension_steps
        return 1
    fi
    local attempt
    for attempt in {1..10}; do
        refresh_state || return 1
        [[ $extension_state == inactive ]] && return 0
        if [[ $extension_state == unknown ]] && (( ! extension_owned )); then
            return 0
        fi
        /bin/sleep 0.3
    done
    if [[ $extension_state == pending ]]; then
        print -u2 'Relance ce programme après le redémarrage demandé par macOS.'
    else
        manual_extension_steps
    fi
    return 1
}

steam_running() {
    /usr/bin/pgrep -x steam_osx >/dev/null 2>&1
}

steam_test_steps() {
    print 'Dans Steam → Paramètres → Manette → Tester les entrées, appuie sur A et bouge un stick.'
}

repair_steam() {
    await_controller || return 1
    release_extension || return 1
    if (( steam_owned )); then
        print 'Steam utilise déjà la manette en USB.'
        steam_test_steps
        return 0
    fi
    if steam_running; then
        print 'Quitte Steam avec ⌘Q, débranche puis rebranche la manette et relance cette action.'
        return 1
    fi
    if ! /usr/bin/open -a Steam; then
        print -u2 'Ouvre Steam depuis Applications pour terminer le test.'
        return 1
    fi
    local attempt
    for attempt in {1..10}; do
        read_usb || break
        (( steam_owned )) && break
        /bin/sleep 0.5
    done
    if (( steam_owned )); then
        print 'Steam a repris la connexion USB de la manette.'
    else
        print 'Steam est ouvert. Consulte la liste Manette et essaie un débranchement-rebranchement si elle est vide.'
    fi
    steam_test_steps
}


start_virtual() {
    local profile=$1
    if [[ $model != joycon2 ]]; then
        await_controller || return 1
        if (( usb_count != 1 )); then
            print -u2 "Branche une seule $model_name pour utiliser le mode virtuel."
            return 1
        fi
        if (( steam_owned )) || { [[ $model == xbox ]] && steam_running; }; then
            print 'Quitte Steam avec ⌘Q, relance la connexion, puis rouvre Steam quand la manette est prête.'
            return 1
        fi
    fi
    init_cli || return 1
    if [[ $model == joycon2 ]] && ! run_ojd record show 057E:2067 --json 2>/dev/null |
        /usr/bin/plutil -extract record.bluetoothLE.vibrationCharacteristic raw -o /dev/null - 2>/dev/null; then
        print -u2 'Mets OpenJoystickDriver à jour vers la version 0.6.0-alpha.2 pour la connexion Bluetooth des Joy-Con 2.'
        print -u2 'https://github.com/xsyetopz/OpenJoystickDriver/releases/tag/0.6.0-alpha.2'
        return 1
    fi
    worker_executable="${resources:h}/Helpers/xbox-usb"
    if (( $+functions[unpack_worker] )); then
        worker_executable="$session_dir/manette-usb"
        if ! unpack_worker > "$worker_executable" || ! /bin/chmod 700 "$worker_executable"; then
            print -u2 'Impossible de préparer le pont de manette.'
            return 1
        fi
    fi
    local service_state result
    service_state=$(run_ojd status --json --timeout 5 2>/dev/null | /usr/bin/plutil -extract service.state raw -o - - 2>/dev/null)
    if [[ ${service_state:l} != running ]]; then
        run_ojd service start --timeout 10 || return 1
    fi
    if [[ $model == xbox ]]; then release_extension || return 1; fi
    if [[ $model == joycon2 ]]; then
        print 'Connexion des Joy-Con 2. Active le Bluetooth et autorise OpenJoystickDriver si macOS le demande.'
        print 'Si InputConfig utilise déjà les Joy-Con 2 en Bluetooth, quitte-le avant d’appuyer sur SYNC.'
    else
        print "Connexion de la $model_name ($model_id)."
    fi
    print 'Garde cette fenêtre ouverte pendant que tu joues. Ctrl+C arrête le pont.'
    if [[ $profile == automatic ]]; then
        print 'Le profil suit le jeu au premier plan. Pour Xbox Cloud Gaming, ouvre Safari.'
    fi
    while true; do
        "$worker_executable" "$profile" "$session_dir/ojd" "$model" &
        worker_pid=$!
        wait "$worker_pid"
        result=$?
        worker_pid=''
        if (( result != 9 )); then
            return $result
        fi
        print 'Connexion USB interrompue. Rebranche la manette pour reprendre.'
        /bin/sleep 1
        while read_usb && (( ! usb_count )); do
            /bin/sleep 1
        done
    done
}

choose_model() {
    case $1 in
        xbox)
            model=xbox
            model_name='Xbox One'
            model_id='045E:02DD'
            vendor_id=1118
            product_id=733
            ;;
        scuf)
            model=scuf
            model_name='SCUF Valor Pro'
            model_id='1B1C:3A03'
            vendor_id=6940
            product_id=14851
            ;;
        joycon2)
            model=joycon2
            model_name='Joy-Con 2'
            ;;
        *) return 2 ;;
    esac
}

run_action() {
    case $1 in
        diagnostic) diagnostic ;;
        steam-direct) [[ $model == xbox ]] && repair_steam ;;
        automatic|game-controller-compatible|sdl-compatible) start_virtual "$1" ;;
        *) print -u2 'Action inconnue.'; return 2 ;;
    esac
}

case ${1:-} in
    --driver-status)
        init_cli || exit 1
        run_ojd status --json --timeout 3
        exit $?
        ;;
    --joycon-battery)
        case ${2:-} in
            057E:2066|057E:2067) ;;
            *) exit 2 ;;
        esac
        init_cli || exit 1
        run_ojd controller capture "$2" --duration 0.75 --json --timeout 4
        exit $?
        ;;
esac

if (( $# )); then
    if ! choose_model "$1"; then
        print -u2 "Usage : ${0:t} xbox|scuf|joycon2 [automatic|diagnostic|game-controller-compatible|sdl-compatible]"
        exit 2
    fi
    run_action "${2:-automatic}"
    exit $?
fi

printf '\n  🎮  Pont manettes\n\n'
while true; do
    printf '  1  Xbox One         USB\n  2  SCUF Valor Pro   USB\n  3  Joy-Con 2        Bluetooth\n  Q  Quitter\n\n'
    read -r 'choice?Choisis ta manette : ' || exit 0
    case ${choice:l} in
        1) choose_model xbox; break ;;
        2) choose_model scuf; break ;;
        3) choose_model joycon2; break ;;
        q) exit 0 ;;
    esac
done

while true; do
    printf '\n  %s\n\n' "$model_name"
    printf '  Entrée  Activer le mode universel\n  M       Profil macOS / Safari fixe\n  S       Profil Steam / SDL fixe\n  D       Diagnostic\n'
    if [[ $model == xbox ]]; then printf '  X       Steam en USB direct\n'; fi
    printf '  Q       Quitter\n\n'
    read -r 'choice?Action : ' || exit 0
    case ${choice:l} in
        ''|a) run_action automatic ;;
        m) run_action game-controller-compatible ;;
        s) run_action sdl-compatible ;;
        d) run_action diagnostic ;;
        x) if [[ $model == xbox ]]; then run_action steam-direct; fi ;;
        q) exit 0 ;;
    esac
done
