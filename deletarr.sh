#!/usr/bin/env bash

set -a # https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html

#####################################################################################################################################################################
# In Radarr you create a Settings/connection/Custom Script named deletarr and select only On Movie Delete
# Then you set the path to this script - Testing will just return a success with an exit code 0 - the script does nothing on this test
# Now when you delete a movie and the file it will trigger the script and do one of two things
# Delete Movie only - This will just trigger the script to log the basic info about the movie and list available torrents to delete in the ~/.deletarr/movie_name.log
# Delete Movie and Movie files and folders - The script will log movie info and also try to delete the torrents and their files via the API - if this was uncommented.
# Note: Until the last curl command is uncommented the script is informative and takes no action even if you chose to delete movie files.
# This is to make sure you can see exactly  what it wants to do and assess the log, like a dry run, before action is taken.
# You can view the ~/.deletarr/movie_name.log created when the action is triggered for output info and troubleshooting
#####################################################################################################################################################################

## connection test ############################
[[ "${radarr_eventtype:=}" == 'Test' ]] && exit

## Testing - error function #################################################################################################################################################################################
# This is a function that detects the PIPESTATUS errors for any element in a single or piped command and will show you the exit status code as well as the index position of the error in the pipe in the log
_pipe_status() {
	return_code=("${PIPESTATUS[@]}")            # set pipestatus to an array now or it will be reset by any new command or action taken.
	return_location=-1                          # set the count start point to -1. An array index starts from 0 so we make sure the first count increment starts at 0 so it matches the location of the error
	unset return_code_outcome                   # unset this to make sure it clear/unset when the function is called so we don't auto exit when using the function
	for return_code in "${return_code[@]}"; do  # loop through the return_code array.
		return_location="$((return_location + 1))" # start the count, starting from 0 so we get 0,0 > 0,1 > 0,2 and so on.
		if [[ "${return_code}" -gt '0' ]]; then    # If any indexed value in the array returns as a non 0 number do this.
			printf '\n%s\n\n' "Pipestatus returned an error at position: ${return_location} with return code: ${return_code}" |& tee -a "${log_name}.log"
			return_code_outcome='1' # set this variable to exit at the end of the function so we can see all errors in the pipe instead of exiting at the first one.
		fi
	done
	[[ "${return_code_outcome}" -eq '1' ]] && exit 1 # if there was any error in the pipe then exit now instead of returning.
	return                                           # if there were no problems we simply return to the main scrpt and do nothing.
}

# https://wiki.servarr.com/radarr/settings#connections
#
# https://github.com/Radarr/Radarr/blob/f890aadffa5ae579bcf65abdcf3e3948837084a9/src/NzbDrone.Core/Notifications/CustomScript/CustomScript.cs
#
# example: radarr_eventtype=Test
#
# event types + Connection Triggers - explanation
#
# Test - Test button - used to check connection test works.
# Grab - On Grab - Be notified when movies are available for download and has been sent to a download client
# Download - On Import - Be notified when movies are successfully imported
# Download - On Upgrade - Be notified when movies are upgraded to a better quality
# Rename - On Rename - Be notified when movies are renamed
# MovieAdded - On Movie Added - Be notified when movies are added to Radarr's library to manage or monitor
# MovieFileDelete - On Movie File Delete - Be notified when movies files are deleted
# MovieFileDelete - On Movie File Delete For Upgrade - Be notified when movie files are deleted for upgrades
# MovieDelete - On Movie Delete - Be notified when movies are deleted
# HealthIssue -# On Health Issue - Be notified on health check failures - Include Health Warnings - Be notified on health warnings in addition to errors.
# ApplicationUpdate - On Application Update - Be notified when Radarr gets updated to a new version
#

## Env Configuration ####################################################################################################################################################
config_dir="${HOME}/.config/deletarr"               # set the config directory
data_dir="${HOME}/.deletarr"                        #locationof movie data folders and files
mkdir -p "${config_dir}"                            # make config dirs for logs and history json
mkdir -p "${data_dir}"                              # make data folder for movie folders
PATH="${data_dir}/bin:${HOME}/bin${PATH:+:${PATH}}" # Set the path so that jq will work if it did not exist or bin was not in the PATH the first time the script executes

## Configuration #########################################################################################
# You can load these settings from the ~/.config/deletarr/config if it exists otherwise use these defaults
if [[ -f "${HOME}/.config/deletarr/config" ]]; then
	# shellcheck source=/dev/null
	source "${HOME}/.config/deletarr/config"
else
	## host Configuration ################################################################################################################
	host="http://localhost" # set your host here - non https is the supported and recommended method for connection to the api's used here

	## Qbittorrent API Configuration ################################################################
	qbt_port="8080"      # set your port here
	qbt_api_version="v2" # api version used
	category="radarr"    # your downloader category here - WIP to find a better way to determine this

	## Radarr API Configuration ###################
	radarr_port="7878"      # set your port here
	radarr_api_version="v3" # api version used
	radarr_api_key=""       # set your API key here
fi

## Testing - Safety ######################################################################################################################################
# Make sure the Radarr API responds before we do anything else or there is no point in the script continuing.
api_status_code="$(curl -o /dev/null -L -s -w "%{http_code}\n" "${host}:${radarr_port}/api/${radarr_api_version}/system/status?apikey=${radarr_api_key}")"

if [[ "${api_status_code}" != '200' ]]; then
	printf '\n%s\n\n' " There is a problem with your Radarr API Configuration settings. Make sure you have all variables correctly."
	exit 1
fi

## logging #############################################################################################################
# Do no set an extension so that we can use log or json extensions per command using a generic &>> "${log_name}.log/json
# This will create a log file in ~/.config/deletarr and either use the default main log or create a movie specific log.
[[ -z "${radarr_movie_path}" ]] && log_name="${config_dir}/deletarr" || log_name="${config_dir}/${radarr_movie_path##*/}"

## get jq #################################################################################################################################################################################################################################################
# Will download jq if the command is not detected in the PATH. Otherwise it just logs the version output.
if ! jq --version &> "${log_name}.log"; then
	case "$(arch)" in
		x86_64) arch="x86_64-linux-musl.tar.gz" ;;
		aarch64) arch="aarch64-linux-musl.tar.gz" ;;
		armhf | armv7*) arch="armv7l-linux-musleabihf.tar.gz" ;;
		armel | armv5* | armv6* | arm) arch="arm-linux-musleabihf" ;;
		*)
			echo "$(arch): This arch is not supported"
			exit 1
			;;
	esac
	wget -q -O- "https://github.com/userdocs/jq-crossbuild/releases/latest/download/${arch}" | tar -xz --strip-components 1 -C "${data_dir}" jq-completed/bin/jq &>> "${log_name}.log" # download the the jq Linux binary and place it in the bin directory
	_pipe_status                                                                                                                                                                       # error testing
	chmod 700 "${data_dir}/bin/jq"                                                                                                                                                     # make the binary executable to the relative user.
fi

## bootstrapping - Radarr API calls ########################################################################################################################################################################
if [[ "${1}" == "bootstrap" ]]; then
	# set history to an array that we are going to loop over 10 to 1000s of times, to avoid spamming the API
	mapfile -t radarr_history < <(curl -sL "${host}:${radarr_port}/api/${radarr_api_version}/history?page=1&pageSize=99999&sortDirection=descending&sortKey=date&apikey=${radarr_api_key}" | jq '.[]')
	# get all movies and set them as compacted json in an array. We will search this for our loop instread of call the API over and over
	mapfile -t movie_info_array < <(curl -sL "${host}:${radarr_port}/api/${radarr_api_version}/movie?apikey=${radarr_api_key}" | jq -c '.[]')

	for movie in "${!movie_info_array[@]}"; do
		radarr_movie_path="$(printf '%s' "${movie_info_array[$movie]}" | jq -r '.path')"                                                                                            # get the path and set it to radarr_movie_path
		mkdir -p "${data_dir}/${radarr_movie_path##*/}"                                                                                                                             # create the data dir using this path
		printf '%s' "${movie_info_array[$movie]}" | jq -r '.' > "${data_dir}/${radarr_movie_path##*/}/movie_info"                                                                   # save all info for this movie to the data dir for this movie
		printf '%s' "${movie_info_array[$movie]}" | jq -r '.id' > "${data_dir}/${radarr_movie_path##*/}/movie_id"                                                                   # save the id to a file so i can easily get it when i need it.
		movie_id="$(printf '%s' "${movie_info_array[$movie]}" | jq -r '.id')"                                                                                                       # get the movieId for this film that we will use to get the unique history
		printf '%s' "${radarr_history[@]}" | jq -r ".[] | select(.movieId==${movie_id})" 2> /dev/null > "${data_dir}/${radarr_movie_path##*/}/movie_history"                        # search the history json for the film history and save to a film in the data dir for this movie
		jq -r '.downloadId | select( . != null )' "${data_dir}/${radarr_movie_path##*/}/movie_history" 2> /dev/null | sort -u > "${data_dir}/${radarr_movie_path##*/}/movie_hashes" # get all unique download hashes from history and set to a file
	done

	printf '\n%s\n\n' " Movie folders created in ${data_dir} with movie specific info dumped to files."
	printf '\n%s\n' " movie_hashes - Any unique torrent hashes stored in the history for that film"
	printf '\n%s\n' " movie_history - The history of all downloads and activity - this is purged when you remove a film from Radarr"
	printf '\n%s\n' " movie_id - The numerical id of the film in the json to get film specific info"
	printf '\n%s\n\n' " movie_info - The genral information about the movie dumped to a file"

	exit
fi

## Testing - Safety ####################################################################################################################
# if the radarr_movie_path variable is not set - then exit now else log the variable info
if [[ -z "${radarr_movie_path}" ]]; then
	printf '\n%s\n\n' "radarr_movie_path is null so it's unsafe not proceed, exiting now with status code 1" |& tee -a "${log_name}.log"
	exit 1
else
	printenv | grep -P "radarr_(.*)=" > "${log_name}.log"
fi

## Radarr API calls ##################################################################################################################################################################################################################################
# Get any download hashes from the movie history via the radarr_movie_id and set them to an array
[[ -n "${radarr_movie_id}" ]] && mapfile -t radarr_download_id_array < <(curl -sL "${host}:${radarr_port}/api/${radarr_api_version}/history/movie?movieId=${radarr_movie_id}&apikey=${radarr_api_key}" | jq -r '.[].downloadId | select( . != null )' | sort -nu)

## logging ##############################################################################################
printf '\n%s\n' "Radarr download_id history hashes = ${radarr_download_id_array[*]}" &>> "${log_name}.log"

################################################################################################################################################
# radarr_eventtype MovieAdded
################################################################################################################################################
if [[ "${radarr_eventtype:=}" == 'MovieAdded' ]]; then
	mkdir -p "${data_dir}/${radarr_movie_path##*/}"
	curl -sL "${host}:${radarr_port}/api/${radarr_api_version}/movie/$radarr_movie_id?apikey=${radarr_api_key}" | jq -r '.' > "${data_dir}/${radarr_movie_path##*/}/movie_info"
	printf '%s' "${radarr_movie_id}" > "${data_dir}/${radarr_movie_path##*/}/movie_id"
fi

## Movie name processing ############################################################################################################
# Processing - File names and special characters from radarr_movie_path are converted to a regex to match all potential torrents
# I am not using radarr_movie_title because radarr_movie_path is used for the path and this is more predictable regarding characters
torrent_name="${radarr_movie_path##*/}"                                      # Some film: Dave's special something - example (2021)
torrent_name="${torrent_name//[ \[\(\)\'\_\:\-\]]/\.\*}"                     # Some.*film.*.*Dave.*s.*special.*something.*.*.*example
torrent_name="$(printf '%s' "${torrent_name}" | sed -r 's/(\.\*){2,}/.*/g')" # Some.*film.*Dave.*s.*special.*something.*example

## logging ##########################################################################
printf '\n%s\n' "regex friendly torrent_name = ${torrent_name}" &>> "${log_name}.log"

## Qbt index array ###########################################################################################################################################################################################################################################
# Set an new array using a list of filtered torrents from the Radarr category. Then search the api for the torrent name and return the line number match for those - then subtract 1 from each to match an index starting from 0
mapfile -t torrent_hash_index_array < <(curl -sL "${host}:${qbt_port}/api/${qbt_api_version}/torrents/info?filter=completed&category=${category}" | jq -r '.[].name | select( . != null )' | grep -in "${torrent_name}" | cut -d: -f1 | awk '{ print $1 - 1}')

## Qbt hash array ##################################################################################################################################################################################
# If the index result is not null then create the hash array from the index array else set the array as an empty array
if [[ -n "${torrent_hash_index_array[*]}" ]]; then
	for torrent_hash in "${torrent_hash_index_array[@]}"; do
		torrent_hash_array+=("$(curl -sL "${host}:${qbt_port}/api/${qbt_api_version}/torrents/info?filter=completed&category=${category}" | jq -r ".[${torrent_hash}].hash | select( . != null )")")
	done
else
	torrent_hash_array=()
fi

## logging ##############################################################################################
printf '\n%s\n' "qBittorrent torrent_hash_array hashes = ${torrent_hash_array[*]}" &>> "${log_name}.log"

## Array processing ###############################################################################################################
# We want to combine the radrr api output with the qbt api output to create a single list of deduplictaed hashes we want to process
mapfile -t combined_hash_array < <(printf '%s\n' "${radarr_download_id_array[@]}" "${torrent_hash_array[@]}" | sort -nu)

## logging ##############################################################################
printf '\n%s\n' "combined_hash_array = ${combined_hash_array[*]}" &>> "${log_name}.log"

## Hash processing loops ##########################
for torrent_hash in "${combined_hash_array[@]}"; do
	hash_to_delete="${torrent_hash}"

	## logging #######################################################################################################################################################################################
	[[ -n ${hash_to_delete} ]] && curl -sL "${host}:${qbt_port}/api/${qbt_api_version}/torrents/info?filter=completed&category=${category}&hashes=${hash_to_delete}" | jq '.[]' &>> "${log_name}.json"

	## Testing - Safety ######################################################################################
	if [[ -z "${hash_to_delete}" ]]; then # safety - if this variable is not set - then exit now
		printf '\n%s\n' "hash_to_delete is null so it's unsafe not proceed, exiting now with status code 1" |& tee -a "${log_name}.log"
		exit 1
	fi

	## Delete torrents via hash list ###########################################################################################################
	if [[ "${radarr_movie_deletedfiles:=}" == 'True' ]]; then # If the user also selected to delete the movie files and folders via the checkbox

		## logging ############################################################################
		printf '\n%s\n\n' "Deleted torrent with hash = ${hash_to_delete}" &>> "${log_name}.log"

		## Delete torrents with hahses using the qbt APi ##############################################################
		# curl -sL "${host}:${qbt_port}/api/${qbt_api_version}/torrents/delete?hashes=${hash_to_delete}&deleteFiles=true"
	fi
done
