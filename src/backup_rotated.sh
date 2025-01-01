#!/bin/bash

###########################
####### LOAD CONFIG #######
###########################

while [ $# -gt 0 ]; do
        case $1 in
                -c)
                        CONFIG_FILE_PATH="$2"
                        shift 2
                        ;;
                *)
                        ${ECHO} "Unknown Option \"$1\"" 1>&2
                        exit 2
                        ;;
        esac
done

if [ -z $CONFIG_FILE_PATH ] ; then
        SCRIPTPATH=$(cd ${0%/*} && pwd -P)
        CONFIG_FILE_PATH="${SCRIPTPATH}/pg_backup.config"
fi

if [ ! -r ${CONFIG_FILE_PATH} ] ; then
        echo "Could not load config file from ${CONFIG_FILE_PATH}" 1>&2
        exit 1
fi

source "${CONFIG_FILE_PATH}"

###########################
#### PRE-BACKUP CHECKS ####
###########################

# Make sure we're running as the required backup user
if [ "$BACKUP_USER" != "" -a "$(id -un)" != "$BACKUP_USER" ] ; then
	echo "This script must be run as $BACKUP_USER. Exiting." 1>&2
	exit 1
fi


###########################
### INITIALISE DEFAULTS ###
###########################

if [ ! $HOSTNAME ]; then
	HOSTNAME="localhost"
fi;

if [ ! $USERNAME ]; then
	USERNAME="postgres"
fi;

if [ -z "$S3_BACKUP_ENABLE" ]; then
	S3_BACKUP_ENABLE=no
else
	if [ -z "$S3_BUCKET" ]; then
		echo "You need to set the S3_BUCKET environment variable."
		exit 1
	fi

	if [ -z "$S3_ENDPOINT" ]; then
		AWS_ARGS=""
	else
		AWS_ARGS="--endpoint-url $S3_ENDPOINT"
	fi

	
fi


###########################
#### START THE BACKUPS ####
###########################

function perform_backups()
{
	SUFFIX=$1
	
	DEST_FOLDER="`date +\%Y-\%m-\%d`$SUFFIX/"
	FINAL_BACKUP_DIR=$BACKUP_DIR$DEST_FOLDER

	echo "Making backup directory in $FINAL_BACKUP_DIR"

	if ! mkdir -p $FINAL_BACKUP_DIR; then
		echo "Cannot create backup directory in $FINAL_BACKUP_DIR. Go and fix it!" 1>&2
		exit 1;
	fi;
	
	#######################
	### GLOBALS BACKUPS ###
	#######################

	echo -e "\n\nPerforming globals backup"
	echo -e "--------------------------------------------\n"

	if [ $ENABLE_GLOBALS_BACKUPS = "yes" ]
	then
		    echo "Globals backup"

		    set -o pipefail
		    if ! pg_dumpall -g -h "$HOSTNAME" -U "$USERNAME" | gzip > $FINAL_BACKUP_DIR"globals".sql.gz.in_progress; then
		            echo "[!!ERROR!!] Failed to produce globals backup" 1>&2
		    else
		            mv $FINAL_BACKUP_DIR"globals".sql.gz.in_progress $FINAL_BACKUP_DIR"globals".sql.gz
		    fi
		    set +o pipefail
	else
		echo "None"
	fi


	###########################
	### SCHEMA-ONLY BACKUPS ###
	###########################
	
	for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }
	do
	        SCHEMA_ONLY_CLAUSE="$SCHEMA_ONLY_CLAUSE or datname ~ '$SCHEMA_ONLY_DB'"
	done
	
	SCHEMA_ONLY_QUERY="select datname from pg_database where false $SCHEMA_ONLY_CLAUSE order by datname;"
	
	echo -e "\n\nPerforming schema-only backups"
	echo -e "--------------------------------------------\n"
	
	SCHEMA_ONLY_DB_LIST=`psql -h "$HOSTNAME" -U "$USERNAME" -At -c "$SCHEMA_ONLY_QUERY" postgres`
	
	echo -e "The following databases were matched for schema-only backup:\n${SCHEMA_ONLY_DB_LIST}\n"
	
	for DATABASE in $SCHEMA_ONLY_DB_LIST
	do
	        echo "Schema-only backup of $DATABASE"
		set -o pipefail
	        if ! pg_dump -Fp -s -h "$HOSTNAME" -U "$USERNAME" "$DATABASE" | gzip > $FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz.in_progress; then
	                echo "[!!ERROR!!] Failed to backup database schema of $DATABASE" 1>&2
	        else
	                mv $FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz.in_progress $FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz
	        fi
	        set +o pipefail
	done
	
	
	###########################
	###### FULL BACKUPS #######
	###########################

	for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }
	do
		EXCLUDE_SCHEMA_ONLY_CLAUSE="$EXCLUDE_SCHEMA_ONLY_CLAUSE and datname !~ '$SCHEMA_ONLY_DB'"
	done

	FULL_BACKUP_QUERY="select datname from pg_database where not datistemplate and datallowconn $EXCLUDE_SCHEMA_ONLY_CLAUSE order by datname;"

	echo -e "\n\nPerforming full backups"
	echo -e "--------------------------------------------\n"

	for DATABASE in `psql -h "$HOSTNAME" -U "$USERNAME" -At -c "$FULL_BACKUP_QUERY" postgres`
	do
		if [ $ENABLE_PLAIN_BACKUPS = "yes" ]
		then
			echo "Plain backup of $DATABASE"
	 
			set -o pipefail
			if ! pg_dump -Fp -h "$HOSTNAME" -U "$USERNAME" "$DATABASE" | gzip > $FINAL_BACKUP_DIR"$DATABASE".sql.gz.in_progress; then
				echo "[!!ERROR!!] Failed to produce plain backup database $DATABASE" 1>&2
			else
				mv $FINAL_BACKUP_DIR"$DATABASE".sql.gz.in_progress $FINAL_BACKUP_DIR"$DATABASE".sql.gz
			fi
			set +o pipefail
                        
		fi

		if [ $ENABLE_CUSTOM_BACKUPS = "yes" ]
		then
			echo "Custom backup of $DATABASE"
	
			if ! pg_dump -Fc -h "$HOSTNAME" -U "$USERNAME" "$DATABASE" -f $FINAL_BACKUP_DIR"$DATABASE".custom.in_progress; then
				echo "[!!ERROR!!] Failed to produce custom backup database $DATABASE"
			else
				mv $FINAL_BACKUP_DIR"$DATABASE".custom.in_progress $FINAL_BACKUP_DIR"$DATABASE".custom
			fi
		fi

	done

	echo -e "\nAll database backups complete!"
}

function upload_backups()
{	
	if [ "$S3_BACKUP_ENABLE" = "yes" ];
	then
		############################
		###### Upload backup #######
		############################
		if [ "$S3_BACKUP_ENABLE" = "yes" ];
		then
			echo "Uploading dump to $S3_BUCKET"
			aws $AWS_ARGS s3 cp $FINAL_BACKUP_DIR "s3://${S3_BUCKET}/${S3_PREFIX}/${DEST_FOLDER}" --recursive
		fi
	fi
}

function cleanup_backups()
{
	SUFFIX=$1
	EXPIRED_DAYS=$2

	if [ "$S3_BACKUP_ENABLE" = "yes" ];
	then
		sec=$((86400*EXPIRED_DAYS))
		date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
		backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00' && contains(Key,'$SUFFIX')].{Key: Key}"

		echo "Removing old $SUFFIX backups from $S3_BUCKET, keeping $EXPIRED_DAYS days."
		aws $AWS_ARGS s3api list-objects \
			--bucket "${S3_BUCKET}" \
			--prefix "${S3_PREFIX}" \
			--query "${backups_query}" \
			--output text \
			| xargs -n1 -t -I 'KEY' aws $AWS_ARGS s3 rm s3://"${S3_BUCKET}"/'KEY'
		echo "Removal complete."
	fi
}

# MONTHLY BACKUPS

DAY_OF_MONTH=`date +%d`
EXPIRED_DAYS=`expr $(($MONTHS_TO_KEEP * 31))`

# if [ $DAY_OF_MONTH -eq 1 ];
if [ $DAY_OF_MONTH -eq 1 ] && [ $MONTHS_TO_KEEP -gt 0 ];
then
	# Delete all expired monthly directories
	find $BACKUP_DIR -maxdepth 1 -mtime +$EXPIRED_DAYS -name "*-monthly" -exec rm -rf '{}' ';'
	        	
	perform_backups "-monthly"
	upload_backups
	cleanup_backups "-monthly" $EXPIRED_DAYS
	
	exit 0;
fi

# WEEKLY BACKUPS

DAY_OF_WEEK=`date +%u` #1-7 (Monday-Sunday)
EXPIRED_DAYS=`expr $((($WEEKS_TO_KEEP * 7) + 1))`

if [ $DAY_OF_WEEK = $DAY_OF_WEEK_TO_KEEP ];
then
	# Delete all expired weekly directories
	find $BACKUP_DIR -maxdepth 1 -mtime +$EXPIRED_DAYS -name "*-weekly" -exec rm -rf '{}' ';'
	        	
	perform_backups "-weekly"
	upload_backups
	cleanup_backups "-weekly" $EXPIRED_DAYS
	
	exit 0;
fi

# DAILY BACKUPS

# Delete daily backups 7 days old or more
find $BACKUP_DIR -maxdepth 1 -mtime +$DAYS_TO_KEEP -name "*-daily" -exec rm -rf '{}' ';'

perform_backups "-daily"
upload_backups
cleanup_backups "-daily"
