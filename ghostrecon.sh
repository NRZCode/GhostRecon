#!/usr/bin/env bash
#
APP='Kraken'
version=0.0.17

# ANSI Colors
function load_ansi_colors() {
  # @C FG Color
  #    |-- foreground color
  export CReset='\e[m' CFGBlack='\e[30m' CFGRed='\e[31m' CFGGreen='\e[32m' \
    CFGYellow='\e[33m' CFGBlue='\e[34m' CFGPurple='\e[35m' CFGCyan='\e[36m' \
    CFGWhite='\e[37m'
  # @C BG Color
  #    |-- background color
  export CBGBlack='\e[40m' CBGRed='\e[41m' CBGGreen='\e[42m' CBGYellow='\e[43m' \
    CBGBlue='\e[44m' CBGPurple='\e[45m' CBGCyan='\e[46m' CBGWhite='\e[47m'
  # @C Attribute
  #    |-- text attribute
  export CBold='\e[1m' CFaint='\e[2m' CItalic='\e[3m' CUnderline='\e[4m' \
    CSBlink='\e[5m' CFBlink='\e[6m' CReverse='\e[7m' CConceal='\e[8m' \
    CCrossed='\e[9m' CDoubleUnderline='\e[21m'
}

progressbar() {
  local progressbar="$workdir/vendor/NRZCode/progressbar/ProgressBar.sh"
  [[ -x "$progressbar" && -z $APP_DEBUG ]] && $progressbar "$@" || cat
}

elapsedtime() {
  code=$?

  printtime=$SECONDS
  [[ $1 == '-p' ]] && {
    ((printtime=SECONDS - partialtime))
    partialtime=$SECONDS
    shift
  }

  status=SUCCESS
  color=${CFGGreen}
  color_status='\e[92m'
  [[ $code -ne 0 ]] && {
    status=ERROR
    color=${CFGRed}
    color_status='\e[91m'
  }

  fmt='+%_Mmin %_Ss'
  [[ $printtime -ge 3600 ]] && fmt='+%_Hh %_Mmin %_Ss'
  elapsed_time=$(date -u -d "@$printtime" "$fmt")

  printf "${CBold}%b%s complete with %b%s%b in %s${CReset}\n" \
    "$color" \
    "$1" \
    "$color_status" \
    "$status" \
    "$color" \
    "${elapsed_time//  / }"
}

cfg_listsections() {
  local file=$1
  grep -oP '(?<=^\[)[^]]+' "$file"
}

read_package_ini() {
  cfg_parser "$inifile"
  while read sec; do
    unset description depends command
    cfg_section_$sec 2>&-
    if [[ $command ]]; then
      descriptions[${sec,,}]="$sec|$description"
      tools[${sec,,}]="$sec|$depends|$command"
    fi
  done < <(cfg_listsections "$inifile")
}

check_dependencies() {
  local pkg='git'
  local ver='2.17.1'

  if ! type -t $pkg >/dev/null; then
    printf '%s: ERROR: Required package %s %s or higher.\n' "$basename" "$pkg" "$ver" 1>&2
    exit 1
  fi

  source "$workdir/vendor/NRZCode/bash-ini-parser/bash-ini-parser"
}

check_inifile() {
  if [[ ! -r "$inifile" ]]; then
    [[ -r "$workdir/package-dist.ini" ]] &&
      cp "$workdir"/package{-dist,}.ini ||
      wget -qO "$workdir/package.ini" https://github.com/NRZCode/GhostRecon/raw/master/package-dist.ini
  fi
  [[ -r "$inifile" ]] || exit 1
}

check_environments() {
  if [[ ! -r "$workdir/.env" ]]; then
    [[ -r "$workdir/.env-dist" ]] &&
      cp "$workdir"/.env{-dist,}
  fi
  [[ -r "$workdir/.env" ]] && source "$workdir/.env"
}

update_tools() {
  echo 'wait a moment...'
  git -C "$workdir" pull --all
  for dir in /usr/local/*; do
    if [[ -d "$dir/.git" ]]; then
      git -C "$dir" pull -q origin master
    fi
  done
}

mklogdir() {
  local logdir=$1
  mkdir -p "$logdir"
  export dtreport=$(date '+%Y%m%d%H%M')
}

dg_menu() {
  dg=(dialog --stdout --title "$title" --backtitle "$backtitle" --checklist "$text" 0 "$width" 0)
  selection=$("${dg[@]}" "${dg_options[@]}")
}

report_tools() {
  tools[mrx]='Mrx Scan Subdomains|subfinder findomain-linux assetfinder|for log in "$logdir/"{assetfinder,findomain,subfinder}.log; do > "$log"; done; sleep 5;findomain-linux -q -t "$domain" > "$logdir/findomain.log"; sleep 5; subfinder -d "$domain" -silent -t 40 -o "$logdir/subfinder.log"; sleep 5; assetfinder -subs-only "$domain" > "$logdir/assetfinder.log"; sort -u "$logdir/"{assetfinder,findomain,subfinder}.log -o "$logfile"; httpx -silent < "$logfile" > "$logdir/${dtreport}httpx.log"'
  tools[dirsearch]='Dirsearch|dirsearch|xargs -L1 python3 /usr/local/dirsearch/dirsearch.py -q -e php,aspx,jsp,html,zip,jar -x 404-499,500-599 -w "$dicc" --random-agent -o "$logfile" -u < <(httpx -silent <<< "$domain"); sleep 5'
  tools[feroxbuster]='Feroxbuster Scan sub-directories|feroxbuster|feroxbuster -q -x php,asp,aspx,jsp,html,zip,jar -A --rate-limit 50 --time-limit 30m -t 30 -L 1 --extract-links -w "$dicc" -o "$logfile" -u "$domain"; sleep 5'
  tools[whatweb]='Whatweb|whatweb|whatweb -q -t 50 --no-errors "$domain" --log-brief="$logfile"'
  tools[owasp]='Owasp Getallurls|waybackurls uro anew|cat "$logdir/${dtreport}httpx.log" | waybackurls | uro | anew | sort -u > "$logfile"'
  tools[crt]='Certificate Search|curl|curl -s "https://crt.sh/?q=%25.${domain}&output=json" | anew > "$logfile"'
  tools[nmap]='Nmap Ports|nmap|nmap -sS -sCV "$domain" -T4 -Pn -oN "$logfile"'
  tools[fnmap]='Nmap|nmap|nmap -n -Pn -sS "$domain" -T4 --open -sV -oN "$logfile"'
}

report() {
  local tbody
  datetime=$(date -d "$(sed -E 's/^.{10}/&:/;s/^.{8}/& /;s/^.{6}/&-/;s/^.{4}/&-/;' <<< "$dtreport")")
  download=${dtreport}${domain}.zip
  ##
  # Page reports
  side=1
  page=2
  while read paginate; do
    printf -v report '%sreport-%02d.html' $dtreport $page
    pagination+="<a style='margin-left: 1em' href='$report'>Página $((page++))</a>"
    (
      sed "s|{{datetime}}|$datetime|;
        s|{{download}}|$download|;
        s|{{domain}}|$domain|g" "$workdir/resources/pagereport.tpl"
      while read tools; do
        for t in $tools; do
          echo -n "<div><h2>$t</h2></div><pre>$(<${pagereports[$t]})</pre>"
        done
        ((side % 2)) && echo -n '</div></article><article class="post-container-right" itemscope="" itemtype="http://schema.org/BlogPosting"><header class="post-header"></header><div class="post-content clearfix" itemprop="articleBody">'
        ((side++))
      done < <(xargs -n3 <<< $paginate)
      echo '</div></article></div></div></div></body></html>'
    ) > "$logdir/$report"
  done < <(xargs -n6 <<< ${!pagereports[@]})
  [[ $pagination ]] && pagination="<a style='margin-left: 1em' href='report.html'>Página 1</a>$pagination"
  ##
  # Subdomains reports
  while read subdomain && [[ $subdomain ]]; do
    logfile="$logdir/${dtreport}${subdomain/:\/\//.}.log"
    n=$(($([[ -f "$logfile" ]] && wc -l < "$logfile" 2>&-)))
    href='#'
    if [[ $n -gt 0 ]]; then
      href="${dtreport}${subdomain/:\/\//.}.html"
      host=$(host "${subdomain#@(ht|f)tp?(s)://}"|sed -z 's/\n/\\n/g')
      nmap=$(sed -z 's/\n/\\n/g' "$logdir/${dtreport}${subdomain#@(ht|f)tp?(s)://}nmap.log")
      screenshots=$(
      for f in $logdir/screenshots/*${subdomain//./_}*png; do
        re="(https?)__${subdomain//./_}__(([0-9]+)__)?[[:alnum:]]+\.png"
        if [[ $f =~ $re ]]; then
          if [[ ${BASH_REMATCH[1]} == https ]]; then
            port=443
          elif [[ ${BASH_REMATCH[1]} == http ]]; then
            port=80
          fi
          port=${BASH_REMATCH[4]:-$port}
          printf '<div class="column">Port %d<a href="%s"><img src="%s"></a></div>' \
            "$port" \
            "screenshots/${f##*/}" \
            "screenshots/${f##*/}"
        fi
      done
      )
      response_headers=$(
      for f in "$logdir/"headers/*${subdomain//./_}*txt; do
        if [[ -f "$f" ]]; then
          printf "==> $f <==\n$(<$f)\n"
        fi
      done
      )
      (
        sed '1,/{{subdomains}}/!d; s/{{subdomains}}.*/\n/' "$workdir/resources/subreport.tpl"
        while read code method lines words chars url; do
          url=$(sed -E 's@((ht|f)tps?[^[:space:]]+)@<a href="\1" target="_blank">\1</a>@g' <<< "$url")
          printf '<tr><td>%s</td><td>%s</td><td>%s</td></tr>' "$code" "$lines $words $chars" "$url"
        done < <(grep -Ev '^(#|$)' "$logfile")
        sed '/{{subdomains}}/,$!d; s/.*{{subdomains}}/\n/' "$workdir/resources/subreport.tpl"
      ) > "$logdir/$href"
      sed -i "s|{{domain}}|$subdomain|g;
        s|{{datetime}}|$datetime|;
        s|{{screenshots}}|$screenshots|;
        s|{{response-headers}}|$response_headers|;
        s|{{nmap}}|${nmap//|/\\|}|;
        s|{{host}}|$host|;" "$logdir/$href"
    fi
    tbody+=$(printf "<tr><td><a href='%s'>%s</a></td><td>%s</td></tr>" "$href" "$subdomain" "$n")
  done < "$logdir/${dtreport}httpx.log"
  ##
  # Domain report
  dig=$(dig "$domain"|sed -z 's/\n/\\n/g')
  host=$(host "$domain"|sed -z 's/\n/\\n/g')
  whois=$(whois "$domain"|sed -z 's/\n/\\n/g')
  nmap=$(sed -z 's/\n/\\n/g' "$logdir/${dtreport}nmap.log")
  nmap_cvss=$(
    while read p cve score url; do
      if [[ $p == '|' && $score =~ [0-9]+\.[0-9] ]]; then
        url=$(sed -E 's@((ht|f)tps?[^[:space:]]+)@<a href="\1" target="_blank">\1</a>@g' <<< "$url")
        printf '<tr><td>%s</td><td>%s</td><td>%s</td></tr>' "$cve" "$score" "$url"
      fi
    done < "$logdir/${dtreport}nmap-cvss.log"
  )
  sed "s|{{domain}}|$domain|g;
    s|{{datetime}}|$datetime|;
    s|{{subdomains}}|$tbody|;
    s|{{dig}}|$dig|;
    s|{{host}}|$host|;
    s|{{whois}}|$whois|;
    s|{{download}}|$download|;
    s|{{nmap-cvss}}|$nmap_cvss|;
    s|{{nmap}}|${nmap//|/\\|}|;" "$workdir/resources/report.tpl" > "$logdir/${dtreport}report-01.html"
  ##
  # Compact reports
  cp $logdir/${dtreport}report-01.html $logdir/report.html
  cd "$logdir"
  zip -q -r ${dtreport}${domain}.zip ${dtreport}*html report.html screenshots/ headers/
  xdg-open "$logdir/${dtreport}report-01.html" &
  ##
  # Menu reports
  btview='<a href="%s" class="mdl-cell mdl-cell--6-col-desktop mdl-cell--4-col-tablet mdl-cell--2-col-phone"><button class="mdl-button mdl-js-button mdl-js-ripple-effect mdl-button--icon" data-upgraded=",MaterialButton,MaterialRipple"><i class="material-icons">insert_chart</i><span class="mdl-button__ripple-container"><span class="mdl-ripple"></span></span></button>Visualizar</a>'
  btdownload='<a href="%s" class="mdl-cell mdl-cell--6-col-desktop mdl-cell--4-col-tablet mdl-cell--2-col-phone"><button class="mdl-button mdl-js-button mdl-js-ripple-effect mdl-button--icon" data-upgraded=",MaterialButton,MaterialRipple"><i class="material-icons">file_download</i><span class="mdl-button__ripple-container"><span class="mdl-ripple"></span></span></button>Download</a>'
  rows=$(
  for domain in $workdir/log/*; do
    for report in $domain/*; do
      if [[ ${report##*/} =~ ^(([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})).* ]]; then
        echo  "${domain##*/}/${BASH_REMATCH[1]}"
      fi
    done
  done | sort -u
  )
  reports=$(
  while read report; do
    domain=${report%%/*}
    if [[ $report =~ (([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})) ]]; then
      printf -v bt1 "$btview" "$domain/${BASH_REMATCH[1]}report-01.html"
      printf -v bt2 "$btdownload" "$domain/${BASH_REMATCH[1]}.zip"
      printf '<tr><td><a href="%s">%s %s/%s/%s %s:%s</a></td><td>%s %s</td></tr>' \
        "$domain/${BASH_REMATCH[1]}report-01.html" \
        "$domain" "${BASH_REMATCH[4]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}" \
        "$bt1" "$bt2"
    fi
  done <<< "$rows"
  )
  sed "s|{{reports}}|$reports|;" "$workdir/resources/menu.tpl" > "$workdir/log/menu.html"
  xdg-open "$workdir/log/menu.html" &
}

banner_logo() {
  echo "
 ██╗  ██╗██████╗  █████╗ ██╗  ██╗███████╗███╗   ██╗
 ██║ ██╔╝██╔══██╗██╔══██╗██║ ██╔╝██╔════╝████╗  ██║
 █████╔╝ ██████╔╝███████║█████╔╝ █████╗  ██╔██╗ ██║
 ██╔═██╗ ██╔══██╗██╔══██║██╔═██╗ ██╔══╝  ██║╚██╗██║
 ██║  ██╗██║  ██║██║  ██║██║  ██╗███████╗██║ ╚████║
 ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝®
                                    version: $version
"
}

banner() {
  {
  banner_logo
  echo "
 🐙 Powerful scan tool and parameter analyzer.

"; } | /usr/games/lolcat

  printf "
 🎯   Target                         〔${CBold}${CFGYellow}https://$domain${CReset}〕
 🚪   Scan Port                      〔true〕
 🧰   Redirect                       〔true〕
 🕘   Started at                     〔%(%Y/%m/%d %H:%M:%S)T〕"
}

usage() {
  usage="

Usage: $basename [OPTIONS]

Short Form	Long Form		Description

 -d		--domain		Scan domain and subdomains
 -dL		--list string    	file containing list of domains for subdomain discovery
 -a 		--anon			Setup usage of anonsurf change IP                       〔 Default: On 〕
 -t		--threads		Number of threads to be used 	 			〔 Default: 20 〕
 -A		--agressive		Use all sources (slow) for enumeration 			〔 Default: Off〕
 -v		--verbose		Enable the verbose mode and display results in realtime 〔 Default: Off〕
 -n		--no-subs		Scan only the domain given in -d domain.com
 -f		--fast-scan		scan without options menu
 -u		--update		Update Kraken for better performance
 -V 		--version               Print current version Kraken
 -h		--help			show the help message and exit
 -m             --max-time int	        minutes to wait for enumeration results 		〔 Default: 10〕
 -T		--timeout int   	seconds to wait before timing out 			〔 Default: 30〕

Example of use:
kraken -d example.com -a off -n"
  banner_logo
  printf "${*:+$*\n}$usage\n"
}

init() {
  local OPTIND OPTARG
  load_ansi_colors

  export domain=${domain#@(ht|f)tp?(s)://}

  if [ -z "$domain" ]; then
    usage; return 1;
  fi
}

user_notification() {
  notify-send -u critical -i bash 'Kraken Reconnaissance' "Recon of $domain completed"
}

run_tools() {
  for tool; do
    [[ $anon_mode == 1 ]] && anonsurf change &> /dev/null
    IFS='|' read app depends cmd <<< ${tools[$tool]}
    if type -t $depends > /dev/null; then
      printf "\n\n${CBold}${CFGCyan}[${CFGWhite}+${CFGCyan}] Starting ${app}${CReset}\n"
      export logfile="$logdir/${dtreport}${tool}.log"; > $logfile
      pagereports[$tool]="$logfile"
      result=$(bash -c "$cmd" 2>>$logerr) | progressbar -s normal -m "${tool^} $domain"
      elapsedtime -p "${tool^}"
    fi
  done
}

run() {
  export logdir=${logdir:-$workdir/log/$domain}
  export logerr="$workdir/${basename%.*}.err"
  mklogdir "$logdir"

  backtitle="Reconnaissence tools [$APP]"
  title="Target's Reconnaissence [$domain]"
  text='Select tools:'
  width=0
  if dg_menu checklist; then
    clear

    banner

    # Tools for report
    run_tools nmap nmap-cvss
    [[ $anon_mode == 1 ]] && anonsurf start &> /dev/null
    run_tools mrx whatweb owasp ${selection,,}

    ##
    # Search and report subdomains
    printf "\n\n${CBold}${CFGCyan}[${CFGWhite}+${CFGCyan}] Starting Scan on Subdomains${CReset}\n"
    aquatone -chrome-path /usr/bin/chromium -thumbnail-size 1440,900 -silent -out "$logdir" 2>>$logerr >/dev/null < "$logdir/${dtreport}mrx.log"
    IFS='|' read app depends cmd <<< ${tools[feroxbuster]}
    (
      while read domain && [[ $domain ]]; do
        logfile="$logdir/${dtreport}${domain/:\/\//.}.log"
        result=$(bash -c "$cmd" 2>>$logerr) | progressbar -s slow -m "Feroxbuster $domain"
        [[ $anon_mode == 1 ]] && anonsurf change &> /dev/null
      done < "$logdir/${dtreport}httpx.log"
    )

    [[ $anon_mode == 1 ]] && anonsurf stop &> /dev/null
    sleep 10
    IFS='|' read app depends cmd <<< ${tools[fnmap]}
    (
      while read domain && [[ $domain ]]; do
        logfile="$logdir/${dtreport}${domain}nmap.log"
        result=$(bash -c "$cmd" 2>>$logerr) | progressbar -s normal -m "Nmap $domain"
      done < "$logdir/${dtreport}mrx.log"
    )
    report

    user_notification
    elapsedtime 'TOTAL Reconaissance'
    return 0
  fi

  clear
}

main() {
  script=$(realpath $BASH_SOURCE)
  dirname=${script%/*}
  readonly basename=${0##*/}
  while [[ $1 ]]; do
    case $1 in
      -h|--help|help) usage; exit 0;;
      -V|--version) echo "$version"; exit 0;;
      -u|--update) update_mode=1; shift;;
      -d|--domain) domain=$2; shift 2;;
      -a|--anon) [[ ${2,,} == @(0|false|off) ]] && anon_mode=0; shift 2;;
      *) shift;;
    esac
  done
  if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    printf '%s: ERROR: Need shell %s %s or greater.\n' "$basename" 'bash' '4.0' 1>&2
    exit 1
  fi
  if [[ 0 != $EUID ]]; then
    printf 'This script must be run as root!\nRun as:\n$ sudo ./%s\n' "$basename $*"
    exit 1
  fi
  workdir=$dirname
  inifile="$workdir/package.ini"

  check_dependencies
  check_inifile
  check_environments

  SECONDS=0
  read_package_ini
  report_tools
  mapfile -t dg_options < <(for tool in "${!descriptions[@]}"; do IFS='|' read t d <<< "${descriptions[$tool]}"; printf "%s\n%s\n$dg_checklist_mode\n" "$t" "$d"; done)

  [[ $update_mode == 1 ]] && update_tools
  shopt -s extglob
  domains="$domain"
  [[ -t 0 ]] || domains="$(</dev/stdin)"
  while read domain && [[ $domain ]]; do
    init
    run
  done <<< "$domains"
}

declare -A tools
declare -A descriptions
declare -A pagereports
dg_checklist_mode=${dg_checklist_mode:-OFF}
anon_mode=1
[[ $BASH_SOURCE == $0 ]] && main "$@"
