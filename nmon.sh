#!/bin/bash

#set -x # for debugging

###    packages required: jq, bc, git

###    if suppressing error messages is preferred, run as './nmon.sh 2> /dev/null'

###    CONFIG    ##################################################################################################
CONFIG=""                # config directory for node, eg. $HOME/.gaia/config
### optional:            #
LOGNAME=""               # a custom log file name can be chosen, if left empty default is nodecheck-<username>.log
LOGPATH="$(pwd)"         # the directory where the log file is stored, for customization insert path like: /my/path
LOGSIZE=200              # the max number of lines after that the log will be trimmed to reduce its size
LOGROTATION="1"          # options for log rotation: (1) rotate to $LOGNAME.1 every $LOGSIZE lines;  (2) append to $LOGNAME.1 every $LOGSIZE lines; (3) truncate $logFile to $LOGSIZE every iteration
SLEEP1="30s"             # polls every SLEEP1 sec
PRECOMMITS="20"          # check last n precommits, can be 0 for no checking
VALIDATORADDRESS=""      # if left empty default is from status call (validator)
CHECKPERSISTENTPEERS="1" # if 1 the number of disconnected persistent peers is checked (when persistent peers are configured in config.toml)
TIMEFORMAT="-u --rfc-3339=seconds" # date format for log line entries
### API access required: #
VALIDATORMETRICS="on"    # advanced validator metrics, api must be enabled in app.toml
GOVERNANCE="on"          # vote checks, 'VALIDATORMETRICS' must be 'on'
VOTEURGENCY="3.0"        # threshold in days for time left for new proposals to become urgent votes
VERSIONCHECK="on"        # checks the git repository for newer versions, 'VALIDATORMETRICS' must be 'on'
VERSIONING="patch"       # 'major.minor.patch-revision', 'patch' recommended for production, 'revision' for beta or rc (testnet)
REMOTEREPOSITORY=""      # remote repository is auto-discovered, however if eg. only the binary is deployed or it is not located under 'SHOME' it fails
DELEGATORADDRESS=""      # the self-delegation address is auto-discovered, however it can fail in case no self-delegation exists
###  internal:           #
colorI='\033[0;32m'      # black 30, red 31, green 32, yellow 33, blue 34, magenta 35, cyan 36, white 37
colorD='\033[0;90m'      # for light color 9 instead of 3
colorE='\033[0;31m'      #
colorW='\033[0;33m'      #
noColor='\033[0m'        # no color
###  END CONFIG  ##################################################################################################

if [ -z $CONFIG ]; then
    echo "please configure the config directory in the script"
    exit 1
fi
url=$(sed '/^\[rpc\]/,/^\[/!d;//d' $CONFIG/config.toml | grep "^laddr\b" | awk -v FS='("tcp://|")' '{print $2}')
chainID=$(jq -r '.result.node_info.network' <<<$(curl -s "$url"/status))
nodeID=$(jq -r '.result.node_info.id' <<<$(curl -s "$url"/status))
if [ -z $url ]; then
    echo "please configure the config directory in the script correctly"
    exit 1
fi
url="http://${url}"

if [ -z $LOGNAME ]; then LOGNAME="nodemonitor-${USER}.log"; fi
logFile="${LOGPATH}/${LOGNAME}"
touch $logFile

echo "log file: ${logFile}"
echo "rpc: ${url}"

if [ -z $VALIDATORADDRESS ]; then
    status=$(curl -s "$url"/status)
    VALIDATORADDRESS=$(jq -r '.result.validator_info.address' <<<$status)
else
    flag1="1"
fi
if [ -z $VALIDATORADDRESS ]; then
    echo "rpc appears to be down, start script again when data can be obtained"
    exit 1
fi

if [ "$flag1" == "1" ]; then
    validators=$(curl -s "$url"/validators)
    validatorPubkey=$(jq -r '.result.validators[] | select(.address=='\"$VALIDATORADDRESS\"') | .pub_key.value' <<<$validators)
else
    validatorPubkey=$(jq -r '.result.validator_info.pub_key.value' <<<$status)
fi

enableAPI=$(sed '/^\[api\]/,/^\[/!d;//d' $CONFIG/app.toml | grep "^enable\b" | awk '{print $3}')
if [ $enableAPI == "true" ]; then
    apiURL=$(sed '/^\[api\]/,/^\[/!d;//d' $CONFIG/app.toml | grep "^address\b" | awk -v FS='("tcp://|")' '{print $2}')
    apiURL="http://${apiURL}"
    nodeInfo=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/base/tendermint/v1beta1/node_info)
    if [ -z "$nodeInfo" ]; then
        echo "node information unavailable, please check api configuration and restart the node."
        exit 1
    fi
    validators=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/staking/v1beta1/validators?pagination.limit=10000)
    pubkey=$(jq -r '.application_version.app_name' <<<$nodeInfo)
    app=$(jq -r '.application_version.name' <<<$nodeInfo)
    appName=$(jq -r '.application_version.app_name' <<<$nodeInfo)
    version=$(jq -r '.application_version.version' <<<$nodeInfo)
    case $VERSIONING in
    revision)
        versionspec="v"$(sed 's/\./\\./g' <<<$(grep -Po '^[0-9]*\.[0-9]*\.' <<<$version))".*$"
        ;;
    patch)
        versionspec="v"$(sed 's/\./\\./g' <<<$(grep -Po '^[0-9]*\.[0-9]*\.' <<<$version))"[0-9]*$"
        ;;
    minor)
        versionspec="v"$(sed 's/\./\\./g' <<<$(grep -Po '^[0-9]*\.' <<<$version))"[0-9]*\.[0-9]*$"
        ;;
    major)
        versionspec="v[0-9]*\.[0-9]*\.[0-9]*$"
        ;;
    esac
    gitCommit=$(jq -r '.application_version.git_commit' <<<$nodeInfo)
    goVersion=$(jq -r '.application_version.go_version' <<<$nodeInfo)
    goVersion=$(sed 's/go version //g' <<<$goVersion)
    moniker=$(jq -r '.validators[] | select(.consensus_pubkey.key=='\"$validatorPubkey\"') | .description.moniker' <<<$validators)
    valcons=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/base/tendermint/v1beta1/validatorsets/latest | jq -r '.validators[] | select(.pub_key.key=='\"$validatorPubkey\"') | .address')
    valoper=$(jq -r '.validators[] | select(.consensus_pubkey.key=='\"$validatorPubkey\"') | .operator_address' <<<$validators)
    addressIdentifier=$(grep -Po 'valoper\K[^ ^]{1,24}' <<<$valoper)
    while true; do
        delegations=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/staking/v1beta1/validators/${valoper}/delegations?pagination.key=${nextKey})
        deladdress=$(jq -r '.delegation_responses[] | select(.delegation.delegator_address|test('\"$addressIdentifier\"')) | .delegation.delegator_address' <<<$delegations)
        if [ ! -z $deladdress ]; then
            DELEGATORADDRESS="$deladdress"
            break
        fi
        nextKey=$(jq -r '.pagination.next_key' <<<$delegations)
        total=$(jq -r '.pagination.total' <<<$delegations)
        if [ $total == "0" ]; then
            echo "delegator address not discovered, please set manually"
            exit
        fi
    done
    echo "api: ${apiURL}"
    echo ""
    echo "application: ${app}"
    echo "app name: ${appName}"
    echo "version: ${version}"
    echo "git commit: ${gitCommit}"
    if [ "$VERSIONCHECK" == "on" ] && [ -z "$REMOTEREPOSITORY" ]; then
        for f in $(find $HOME -name .git); do
            if [ "$(git --git-dir $f log --format=short | grep -c $gitCommit)" -ge "1" ]; then
                REMOTEREPOSITORY=$(git --git-dir $f config --get remote.origin.url)
                break
            fi
        done
        if [ -z $REMOTEREPOSITORY ]; then
            echo "remote git repository not found, please specify on config or disable VERSIONCHECK"
            exit 1
        fi
        echo "remote repository: ${REMOTEREPOSITORY}"
    fi
    echo "go version: ${goVersion}"
else
    if [ $VALIDATORMETRICS == "on" ]; then
        echo "please enable the api in app.toml"
        exit 1
    fi
fi

echo ""
echo "chain id: ${chainID}"
echo "node id: ${nodeID}"
echo "moniker: ${moniker}"
echo "validator address: $VALIDATORADDRESS"
echo "operator address: ${valoper}"
echo "consensus address: ${valcons}"
if [ ! -z $DELEGATORADDRESS ]; then echo "delegator address: ${DELEGATORADDRESS}"; fi

#netMoniker=$(cat $CONFIG/config.toml | grep "^moniker\b" | awk '{print $3}')
#echo "net moniker: $(sed -e 's/^"//' -e 's/"$//' <<<$netMoniker)"

echo ""
if [ "$CHECKPERSISTENTPEERS" -eq 1 ]; then
    persistentPeers=$(sed '/^\[p2p\]/,/^\[/!d;//d' $CONFIG/config.toml | grep "^persistent_peers\b" | awk -v FS='("|")' '{print $2}')
    persistentPeerIds=$(sed 's/,//g' <<<$(sed 's/@[^ ^,]\+/ /g' <<<$persistentPeers))
    totPersistentPeerIds=$(wc -w <<<$persistentPeerIds)
    persistentPeersMatchCount=0
    netInfo=$(curl -s "$url"/net_info)
    if [ -z "$netInfo" ]; then
        echo "lcd appears to be down, start script again when data can be obtained"
        exit 1
    fi
    for id in $persistentPeerIds; do
        nPersistentPeersMatch=$(grep -c "$id" <<<$netInfo)
        if [ $nPersistentPeersMatch -eq 0 ]; then
            persistentPeersMatch="$id $persistentPeersMatch"
            ((persistentPeersMatchCount += 1))
        fi
    done
    persistentPeersOff=$(($totPersistentPeerIds - $persistentPeersMatchCount))
    echo "$totPersistentPeerIds persistent peer(s): $persistentPeerIds"
    echo "$persistentPeersMatchCount persistent peer(s) off: $persistentPeersMatch"
fi

echo ""
if [ $PRECOMMITS -eq 0 ]; then echo "precommit checks: off"; else echo "precommit checks: on"; fi
if [ $CHECKPERSISTENTPEERS -eq 0 ]; then echo "persistent peer checks: off"; else echo "persistent peer checks: on"; fi
if [[ "$VALIDATORMETRICS" == "on" ]]; then echo "validator metrics: on"; else echo "validator metrics: off"; fi
if [[ "$GOVERNANCE" == "on" ]] && [[ "$VALIDATORMETRICS" == "on" ]]; then echo "governance check: vote urgency ${VOTEURGENCY} days"; else echo "governance check: off"; fi
if [[ "$VERSIONCHECK" == "on" ]] && [[ "$VALIDATORMETRICS" == "on" ]]; then echo "git version check: $VERSIONING"; else echo "git version check: off"; fi
echo ""

status=$(curl -s "$url"/status)
height=$(jq -r '.result.sync_info.latest_block_height' <<<$status)
blockInfo=$(curl -s "$url"/block?height="$height")
if [ $height -gt $PRECOMMITS ]; then
    if [ "$(grep -c 'precommits' <<<$blockInfo)" != "0" ]; then versionIdentifier="precommits"; elif [ "$(grep -c 'signatures' <<<$blockInfo)" != "0" ]; then versionIdentifier="signatures"; else
        echo "json parameters of this version not recognised"
        exit 1
    fi
else
    echo "wait for $PRECOMMITS blocks and start again..."
    exit 1
fi

logLines=$(wc -l <$logFile)
if [ $logLines -gt $LOGSIZE ]; then sed -i "1,$(($logLines - $LOGSIZE))d" $logFile; fi # the log file is trimmed for logsize

date=$(date $TIMEFORMAT)
echo "$date status=scriptstarted chainID=$chainID" >>$logFile

while true; do
    status=$(curl -s "$url"/status)
    result=$(grep -c "result" <<<$status)
    if [ "$result" != "0" ]; then
        peers=$(curl -s "$url"/net_info | jq -r '.result.n_peers')
        if [ -z $peers ]; then peers="na"; fi
        height=$(jq -r '.result.sync_info.latest_block_height' <<<$status)
        blockTime=$(jq -r '.result.sync_info.latest_block_time' <<<$status)
        catchingUp=$(jq -r '.result.sync_info.catching_up' <<<$status)
        votingPower=$(jq -r '.result.validator_info.voting_power' <<<$status)
        if [ $catchingUp == "false" ]; then catchingUp="synced"; elif [ $catchingUp == "true" ]; then catchingUp="catchingup"; fi
        if [ "$CHECKPERSISTENTPEERS" -eq 1 ]; then
            persistentPeersMatch=0
            netInfo=$(curl -s "$url"/net_info)
            for id in $persistentPeerIds; do
                persistentPeersMatch=$(($persistentPeersMatch + $(grep -c "$id" <<<$netInfo)))
            done
            persistentPeersOff=$(($totPersistentPeerIds - $persistentPeersMatch))
        else
            persistentPeersOff=0
        fi
        consdump=$(curl -s "$url"/dump_consensus_state)
        validators=$(jq -r '.result.round_state.validators.validators' <<<$consdump)
        #activeValidators=$(jq -r '.result.round_state.validators.validators | length' <<<$consdump)
        isValidator=$(grep -c "$VALIDATORADDRESS" <<<$validators)
        pctTotCommits=$(jq -r '.result.round_state.last_commit.votes_bit_array' <<<$consdump)
        pctTotCommits=$(grep -Po "=\s+\K[^ ^]+" <<<$pctTotCommits)
        if [ "$isValidator" != "0" ]; then
            isValidator="true"
            validators=$(jq -r '. | sort_by((.voting_power)|tonumber) | reverse' <<<$validators)
            precommitCount=0
            for ((i = $(($height - $PRECOMMITS + 1)); i <= $height; i++)); do
                validatorAddresses=$(curl -s "$url"/block?height="$i")
                validatorAddresses=$(jq ".result.block.last_commit.${versionIdentifier}[].validator_address" <<<$validatorAddresses)
                validatorPrecommit=$(grep -c "$VALIDATORADDRESS" <<<$validatorAddresses)
                precommitCount=$(($precommitCount + $validatorPrecommit))
            done
            if [ $PRECOMMITS -eq 0 ]; then pctPrecommits="1.0"; else pctPrecommits=$(echo "scale=2 ; $precommitCount / $PRECOMMITS" | bc); fi

            validatorInfo="isValidator=$isValidator pctPrecommits=$pctPrecommits pctTotCommits=${pctTotCommits}"
        else
            isValidator="false"
            validatorInfo="isValidator=$isValidator"
        fi
        if [ "$VALIDATORMETRICS" == "on" ]; then
            validator=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/staking/v1beta1/validators/${valoper})
            isJailed=$(jq -r '.validator.jailed' <<<$validator)
            if [[ "$isJailed" != "false" ]] && [[ "$isJailed" != "true" ]]; then
                validatorMetrics=""
            else
                #votingPower=$(jq -r '.result.validator_info.voting_power' <<<$status)
                votingPower=$(jq -r '.validator | select(.operator_address == '\"$valoper\"') | .tokens' <<<$validator)
                votingPower=$(echo "scale=2 ; $votingPower / 1000000.0" | bc)
                activeValidators=$(jq -r 'length' <<<$validators)
                rank=$(jq -r 'map(.address == '\"$VALIDATORADDRESS\"') | index(true)' <<<$validators)
                ((rank += 1))
                validatorParams=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/staking/v1beta1/params)
                totValidators=$(jq -r '.params.max_validators' <<<$validatorParams)
                bondDenomination=$(jq -r '.params.bond_denom' <<<$validatorParams)
                pctRank=$(echo "scale=2 ; $rank / $totValidators" | bc)
                pctActiveValidators=$(echo "scale=2 ; $activeValidators / $totValidators" | bc)
                validatorCommission=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/distribution/v1beta1/validators/${valoper}/commission)
                validatorCommission=$(jq -r '.commission.commission[] | select(.denom == '\"$bondDenomination\"') | .amount' <<<$validatorCommission)
                validatorCommission=$(echo "scale=2 ; $validatorCommission / 1000000.0" | bc)
                delegatorRewards=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/distribution/v1beta1/delegators/${DELEGATORADDRESS}/rewards)
                delegatorReward=$(jq -r '.rewards[] | select(.validator_address == '\"$valoper\"') | .reward[] |  select(.denom == '\"$bondDenomination\"') | .amount' <<<$delegatorRewards)
                delegatorReward=$(echo "scale=2 ; $delegatorReward / 1000000.0" | bc)

                validatorMetrics=" isJailed=$isJailed stake=$votingPower rank=$rank pctRank=$pctRank activeValidators=$activeValidators pctActiveValidators=$pctActiveValidators validatorCommission=$validatorCommission delegatorReward=${delegatorReward}"
                if [ "$GOVERNANCE" == "on" ]; then
                    proposals=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/gov/v1beta1/proposals?pagination.limit=10000)
                    votingPeriodIds=$(jq -r '.proposals[] | select(.status == "PROPOSAL_STATUS_VOTING_PERIOD") | .proposal_id' <<<$proposals)
                    newProposalsCount=0
                    urgentVotes=0
                    gov=""
                    for id in $votingPeriodIds; do
                        #echo $id
                        proposal=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/gov/v1beta1/proposals/${id})
                        vote=$(curl -s -X GET -H "Content-Type: application/json" $apiURL/cosmos/gov/v1beta1/proposals/${id}/votes/${DELEGATORADDRESS})
                        votingEndTime=$(jq -r ".proposal.voting_end_time" <<<$proposal)
                        #echo $proposal
                        #echo $vote
                        #echo $votingEndTime
                        #if [ $(jq -r ".code" <<<$vote) == "3" ]; then
			if [ -z "$(jq -r '.vote' <<<$vote)" ]; then
			    ((newProposalsCount += 1))
			    voteDaysLeft=$(echo "scale=2 ; ($(date -d $votingEndTime +%s) - $(date -d now +%s)) / 86400" | bc)
                            voteDaysLeft=$(echo $voteDaysLeft | bc | awk '{printf "%f", $0}')
                            #echo $voteDaysLeft
                            #echo $VOTEURGENCY
                            if (($(echo "$voteDaysLeft < $VOTEURGENCY" | bc -l))); then ((urgentVotes = $urgentVotes + 1)); fi

                        fi
                    done
                    govInfo=" newProposals=$newProposalsCount urgentVotes=$urgentVotes"
                fi
                if [ "$VERSIONCHECK" == "on" ]; then
                    versions=$(echo $"$(git ls-remote --tags --refs --sort v:refname $REMOTEREPOSITORY)" | grep $versionspec)
                    versions_=$(echo $"$versions" | grep $version -A 10)
                    versions=$(wc -l <<<$versions_)
                    if [ "$versions" -gt "1" ]; then
                        isLatestVersion="false"
                    elif [ "$versions" -eq "1" ]; then
                        isLatestVersion="true"
                    else
                        isLatestVersion=""
                    fi
                    versionInfo=" isLatestVersion=$isLatestVersion"
                fi
            fi
        fi
        status="$catchingUp"
        now=$(date $TIMEFORMAT)
        blockHeightFromNow=$(($(date +%s -d "$now") - $(date +%s -d $blockTime)))
        variables="status=$status height=$height elapsed=$blockHeightFromNow peers=$peers persistentPeersOff=$persistentPeersOff $validatorInfo${validatorMetrics}${govInfo}${versionInfo}"
    else
        status="error"
        now=$(date $TIMEFORMAT)
        variables="status=$status"
    fi

    logEntry="[$now] $variables"
    echo "$logEntry" >>$logFile

    logLines=$(wc -l <$logFile)
    if [ $logLines -gt $LOGSIZE ]; then
        case $LOGROTATION in
        1)
            mv $logFile "${logFile}.1"
            touch $logFile
            ;;
        2)
            echo "$(cat $logFile)" >>${logFile}.1
            >$logFile
            ;;
        3)
            sed -i '1d' $logFile
            if [ -f ${logFile}.1 ]; then rm ${logFile}.1; fi # no log rotation with option (3)
            ;;
        *) ;;
        esac
    fi

    case $status in
    synced)
        color=$colorI
        ;;
    error)
        color=$colorE
        ;;
    catchingUp)
        color=$colorW
        ;;
    *)
        color=$noColor
        ;;
    esac

    pctPrecommits=$(awk '{printf "%f", $0}' <<<"$pctPrecommits")
    if [[ "$isValidator" == "true" ]] && [[ "$pctPrecommits" < "1.0" ]]; then color=$colorW; fi
    if [[ "$isValidator" == "false" ]] && [[ $VALIDATORMETRICS == "on" ]]; then color=$colorW; fi

    logEntry="$(sed 's/[^ ]*[\=]/'\\${color}'&'\\${noColor}'/g' <<<$logEntry)"
    echo -e $logEntry
    echo -e "${colorD}sleep ${SLEEP1}${noColor}"

    variables_=""
    for var in $variables; do
        var_=$(grep -Po '^[0-9a-zA-Z_-]*' <<<$var)
        var_="$var_=\"\""
        variables_="$var_; $variables_"
    done
    #echo $variables_
    eval $variables_

    sleep $SLEEP1
done
