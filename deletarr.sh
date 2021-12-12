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
###############################################

## Env Configuration ####################################################################################################################################
mkdir -p "${HOME}/.deletarr"        # data folder for log files
PATH="${HOME}/bin${PATH:+:${PATH}}" # Set the path so that jq will work if it did not exist or bin was not in the PATH the first time the script executes
host="http://localhost"             # set your host here
#########################################################################################################################################################

## Qbittorrent API Configuration ################################################################
qbt_port="8080"      # set your port here
qbt_api_version="v2" # api version used
category="radarr"    # your downloader category here - WIP to find a better way to determine this
#################################################################################################

## Radarr API Configuration #####################
radarr_port="7878"
radarr_api_version="v3"
radarr_api_key=""
#################################################

## logging ##############################################################################################################################
[[ -z "${radarr_movie_path}" ]] && log_name="${HOME}/.deletarr/deletarr.log" || log_name="${HOME}/.deletarr/${radarr_movie_path##*/}.log"
#########################################################################################################################################

## Testing - error function #################################################################################################################################################################################
# This is a function that detects the PIPESTATUS errors for any element in a single or piped command and will show you the exit status code as well as the index position of the error in the pipe in the log
_pipe_status() {
	return_code=("${PIPESTATUS[@]}")            # set pipestatus to an array now or it will be reset by any new command or action taken.
	return_location=-1                          # set the count start point to -1. An array index starts from 0 so we make sure the first count increment starts at 0 so it matches the location of the error
	unset return_code_outcome                   # unset this to make sure it clear/unset when the function is called so we don't auto exit when using the function
	for return_code in "${return_code[@]}"; do  # loop through the return_code array.
		return_location="$((return_location + 1))" # start the count, starting from 0 so we get 0,0 > 0,1 > 0,2 and so on.
		if [[ "${return_code}" -gt '0' ]]; then    # If any indexed value in the array returns as a non 0 number do this.
			printf '\n%s\n\n' " Pipestatus returned an error at position: ${return_location} with return code: ${return_code}" &>> "${log_name}"
			return_code_outcome='1' # set this variable to exit at the end of the function so we can see all errors in the pipe instead of exiting at the first one.
		fi
	done
	[[ "${return_code_outcome}" -eq '1' ]] && exit 1 # if there was any error in the pipe then exit now instead of returning.
	return                                           # if there were no problems we simply return to the main scrpt and do nothing.
}
##############################################################################################################################################################################################################

## get jq ##############################################################################################################################################################################
# Will download jq if the command is not detected in the PATH. Otherwise it just logs the version output.
if ! jq --version &> "${log_name}"; then
	mkdir -p "${HOME}/bin"                                                                                          # create the bin directory relative to the user running the script
	wget -O "${HOME}/bin/jq" "https://github.com/stedolan/jq/releases/latest/download/jq-linux64" &>> "${log_name}" # download the the jq Linux binary and place it in the bin directory
	_pipe_status                                                                                                    # error testing
	chmod 700 "${HOME}/bin/jq"                                                                                      # make the binary executable to the relative user.
fi
#######################################################################################################################################################################################

## Testing - Safety #########################################################################################
# if the radarr_movie_path variable is not set - then exit now else log the variable info
if [[ -z "${radarr_movie_path}" ]]; then
	printf '\n%s\n\n' " radarr_movie_path is null so it's unsafe not proceed, exiting now with status code 1"
	exit 1
else
	printenv | grep -P "radarr_(.*)=" > "${log_name}"
fi
#############################################################################################################

## Radarr API calls ##################################################################################################################################################################################################################################
# Get any download hashes from the movie history via the radarr_movie_id and set them to an array
[[ -n "${radarr_movie_id}" ]] && mapfile -t radarr_download_id_array < <(curl -sL "${host}:${radarr_port}/api/${radarr_api_version}/history/movie?movieId=${radarr_movie_id}&apikey=${radarr_api_key}" | jq -r '.[].downloadId | select( . != null )')
######################################################################################################################################################################################################################################################

## logging ############################################################################################
printf '\n%s\n' "Radar download_id history hashes = ${radarr_download_id_array[*]}" &>> "${log_name}"
#######################################################################################################

## Movie name processing ##########################################################################################################################################
# Processing - File names and characters from radarr_movie_path are converted to a regex that we will use with case insenstive grep to match all potential torrents
# I am not using radarr_movie_title because radarr_movie_path is used for the path and this is more predictable regarding characters and has the movie year
torrent_name="${radarr_movie_path##*/}"                                      # Some film: Dave's special something - example (2021)
torrent_name="${torrent_name//[ \(\)\'\_\:\-]/\.\*}"                         # Some.*film.*.*Dave.*s.*special.*something.*.*.*example.*.*2021.*
torrent_name="$(printf '%s' "${torrent_name}" | sed -r 's/(\.\*){2,}/.*/g')" # Some.*film.*Dave.*s.*special.*something.*example.*2021.*
###################################################################################################################################################################

## logging ########################################################################
printf '\n%s\n' "regex friendly torrent_name = ${torrent_name}" &>> "${log_name}"
###################################################################################

## qbt index array ###########################################################################################################################################################################################################################################
# Set an new array using a list of filtered torrents from the Radarr category. Then search the api for the torrent name and return the line number match for those - then subtract 1 from each to match an index starting from 0
mapfile -t torrent_hash_index_array < <(curl -sL "${host}:${qbt_port}/api/${qbt_api_version}/torrents/info?filter=completed&category=${category}" | jq -r '.[].name | select( . != null )' | grep -in "${torrent_name}" | cut -d: -f1 | awk '{ print $1 - 1}')
##############################################################################################################################################################################################################################################################

## qbt hash array ##################################################################################################################################################################################
# If the index result is not null then create the hash array from the index array else set the array as an empty array
if [[ -n "${torrent_hash_index_array[*]}" ]]; then
	for torrent_hash in "${torrent_hash_index_array[@]}"; do
		torrent_hash_array+=("$(curl -sL "${host}:${qbt_port}/api/${qbt_api_version}/torrents/info?filter=completed&category=${category}" | jq -r ".[${torrent_hash}].hash | select( . != null )")")
	done
else
	torrent_hash_array=()
fi
####################################################################################################################################################################################################

## Array processing ###############################################################################################################
# We want to combine the radrr api output with the qbt api output to create a single list of deduplictaed hashes we want to process
mapfile -t combined_hash_array < <(printf '%s\n' "${radarr_download_id_array[@]}" "${torrent_hash_array[@]}" | awk '!a[$0]++')
###################################################################################################################################

## logging ##########################################################################
printf '\n%s\n\n' "combined_hash_array = ${combined_hash_array[*]}" &>> "${log_name}"
#####################################################################################

## Hash processing ##################################################################################################################################################################################################
for torrent_hash in "${combined_hash_array[@]}"; do
	hash_to_delete="${torrent_hash}"

	## logging ##################################################################################################################################################################################
	[[ -n ${hash_to_delete} ]] && curl -sL "${host}:${qbt_port}/api/${qbt_api_version}/torrents/info?filter=completed&category=${category}&hashes=${hash_to_delete}" | jq '.[]' &>> "${log_name}"
	#############################################################################################################################################################################################

	## Testing - Safety ######################################################################################
	if [[ -z "${hash_to_delete}" ]]; then # safety - if this variable is not set - then exit now
		printf '\n%s\n\n' " hash_to_delete is null so it's unsafe not proceed, exiting now with status code 1"
		exit 1
	fi
	##########################################################################################################

	## Delete torrents via hash list ###########################################################################################################
	if [[ "${radarr_movie_deletedfiles:=}" == 'True' ]]; then # If the user also selected to delete the movie files and folders via the checkbox
		## logging ########################################################################
		printf '\n%s\n\n' "Deleted torrent with hash = ${hash_to_delete}" &>> "${log_name}"
		###################################################################################

		## Delete torrents with hahses using the qbt APi ##############################################################
		# curl -sL "${host}:${qbt_port}/api/${qbt_api_version}/torrents/delete?hashes=${hash_to_delete}&deleteFiles=true"
		###############################################################################################################
	fi
	###########################################################################################################################################
done
#####################################################################################################################################################################################################################
