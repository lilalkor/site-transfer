#!/bin/bash

SCRIPT_DIR="$(dirname "$0")"
CMS_ARR=(`grep -vE '^#' $SCRIPT_DIR/cms.list`)

sed -i -e 's|::|/::|' -e 's|//*|/|g' sites.list
SITES=(`grep -vE '^#' $SCRIPT_DIR/sites.list | awk -F:: '{print $1}'`)
TARGETS=(`grep -vE '^#' $SCRIPT_DIR/sites.list | awk -F:: '{print $2}'`)
REM_USERS=(`grep -vE '^#' $SCRIPT_DIR/sites.list | awk -F:: '{print $3}'`)

TXT_GRN='\e[0;32m'
TXT_RED='\e[0;31m'
TXT_YLW='\e[0;33m'
TXT_RST='\e[0m'

MSG_OK="${TXT_GRN}OK${TXT_RST}"
MSG_WRN="${TXT_YLW}WARNING${TXT_RST}"
MSG_ERR="${TXT_RED}ERROR${TXT_RST}"

TARGET_IP=$1
PANEL_USER=$2


# Function to echo result based on exit code
function echo_result {
	if [ `echo $?` -eq 0 ]; then
		echo -e "INFO: [$MSG_OK]"
	else
		echo -e "$MSG_ERR: Failed!"
	fi
}

# Function to create www-domains via panel
function create_domains {
	case $PANEL in
		FastPanel )
			COUNTER=0
                        for TARGET in ${TARGETS[@]}; do
                                DOMAIN=`echo "$TARGET" | awk -F\/ '{print $(NF-1)}'`
				TMP_SQL="fast_sql"
				((COUNTER++))
				echo -e "INFO: Creating domain $DOMAIN"
				echo 'INSERT INTO `web_config` (`domain`, `alias`, `charset`, `index_page`, `php`, `perl`, `enabled`, `admin_email`, `port`, `ip`, `ssi`, `user`, `group`, `status`, `backup`)' > $SCRIPT_DIR/$TMP_SQL
				echo "VALUES ('$DOMAIN', 'www.$DOMAIN', 'UTF-8', 'index.php index.html index.htm', 1, 0, 1, 'admin@$DOMAIN', 80, '$TARGET_IP', 0, 'admin', 'admin', 'CREATED', 0);" >> $SCRIPT_DIR/$TMP_SQL
				rsync $SCRIPT_DIR/$TMP_SQL root@$TARGET_IP:~/
				ssh root@$TARGET_IP "$SQL_COMMAND fastpanel < ~/$TMP_SQL && rm ~/$TMP_SQL"
				echo_result
                        	echo -e "-----"
                        done			
		;;
		ISPmanager4 )
			COUNTER=0
                        for TARGET in ${TARGETS[@]}; do
                                DOMAIN=`echo "$TARGET" | awk -F\/ '{print $(NF-1)}'`
                                USER=${REM_USERS[$COUNTER]}
                                ((COUNTER++))
                                echo -e "INFO: Creating domain $DOMAIN"
                                ssh root@$TARGET_IP "/usr/local/ispmgr/sbin/mgrctl wwwdomain.edit alias="www.$DOMAIN" index="index.php" admin="webmaster@$DOMAIN" domain="$DOMAIN" ip=$TARGET_IP php=phpfcgi owner="$USER" sok=ok"
                                echo_result
                                echo -e "-----"
			done
		;;
		ISPmanager5 )
			COUNTER=0
			for TARGET in ${TARGETS[@]}; do
                                DOMAIN=`echo "$TARGET" | awk -F\/ '{print $(NF-1)}'`
				USER=${REM_USERS[$COUNTER]}
				((COUNTER++))
				echo -e "INFO: Creating domain $DOMAIN"
				ssh root@$TARGET_IP "/usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain.edit aliases=www.$DOMAIN dirindex=index.php email="webmaster@$DOMAIN" name="$DOMAIN" owner="$USER" sok=ok"
				echo_result
				echo -e "-----"
			done
		;;
		* )
			echo -e "INFO: No panel - you need to create domains manually"
		;;
	esac
}

# Function to create, check and upload dumps
function mysql_dump {
	MODE=$1
	case $MODE in
		dump )
			DUMP_DIR="${SCRIPT_DIR}/dumps_for_migration"
			DUMP_FILE="$DUMP_DIR/$DBNAME.sql"
			DUMP_CMD="mysqldump -u$DBUSER -p$DBPASS -h$DBHOST $DBNAME > $DUMP_FILE"

			# Create dump_dir if not exist 
			if [ ! -d $DUMP_DIR ]; then mkdir $DUMP_DIR; fi

			# Echo command and create dump
		        echo -e "INFO: Dumping base $DBNAME (${TXT_YLW} $DUMP_CMD ${TXT_RST}) "
			eval $DUMP_CMD
		        echo_result
		;;
		check )
			# Checking file existance...
                        if [ -f $DUMP_FILE ]; then
				# ...not empty...
                                if [ `wc -m $DUMP_FILE | awk '{print $1}'` -gt 0 ]; then
					# ...and has at least one INSERT in it.
                                        if [ `grep -q INSERT $DUMP_FILE; echo $?` -eq 0 ]; then
                                                echo -e "INFO: Dump in file $DUMP_FILE exists, not empty and there is INSERT in it. Seems $MSG_OK."
                                        else
                                                echo -e "$MSG_WRN: Dump in file $DUMP_FILE exists, but there is no INSERT in it. Probably wrong DB name!"
                                                ((ERR_CNT++))
                                        fi
					# It is good enough to store DB info and create DB on remote host
					DB_CONN="$DBNAME::$DBUSER::$DBPASS::$REMOTE_USER"
					DB_ARRAY=("${DB_ARRAY[@]}" "$DB_CONN")
                                else
                                        echo -e "$MSG_ERR: Dump in file $DUMP_FILE exists, but it is empty!"
                                        ((ERR_CNT++))
                                fi
                        else
                                echo -e "$MSG_ERR: There is no dump $DUMP_FILE"
                                ((ERR_CNT++))
                        fi

		;;
		restore )
			for DB_STRING in ${DB_ARRAY[@]}; do
				DBNAME=`echo $DB_STRING | awk -F:: '{print $1}'`
				DBUSER=`echo $DB_STRING | awk -F:: '{print $2}'`
				DBPASS=`echo $DB_STRING | awk -F:: '{print $3}'`
				PANEL_USER=`echo $DB_STRING | awk -F:: '{print $4}'`

				DUMP_FILE="$DUMP_DIR/$DBNAME.sql"

				# Checking if DB already exists
				DB_EXISTS=""
				DB_EXISTS=`ssh root@$TARGET_IP "$SQL_COMMAND -e \"SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$DBNAME'\" -BN"`

				if [ "$DB_EXISTS" == "" ]; then
					echo -e "INFO: Creating DB $DBNAME with $PANEL"
				        case $PANEL in
				                FastPanel )
							ssh root@$TARGET_IP "$SQL_COMMAND -e \"CREATE DATABASE \\\`$DBNAME\\\`\""
							echo_result
							# Grant privileges on DB
							echo -e "INFO: Granting privileges to user."
							ssh root@$TARGET_IP "$SQL_COMMAND -e \"GRANT ALL PRIVILEGES on \\\`$DBNAME\\\`.* to \\\`$DBUSER\\\`@localhost IDENTIFIED BY \\\"$DBPASS\\\"\""
							echo_result
							echo -e "-----"
				                ;;
				                ISPmanager4 )
							ssh root@$TARGET_IP "/usr/local/ispmgr/sbin/mgrctl db.edit name='$DBNAME' dbusername='$DBUSER' dbpassword='$DBPASS' owner='$PANEL_USER' sok=ok"
							echo_result
							echo -e "-----"
				                ;;
				                ISPmanager5 )
							ssh root@$TARGET_IP "/usr/local/mgr5/sbin/mgrctl -m ispmgr db.edit name='$DBNAME' username='$DBUSER' password='$DBPASS' owner='$PANEL_USER' sok=ok"
							echo_result
							echo -e "-----"
				                ;;
				                Debian )
							ssh root@$TARGET_IP "$SQL_COMMAND -e \"CREATE DATABASE \\\`$DBNAME\\\`\""
							echo_result
							# Grant priveleges on DB
							echo -e "INFO: Granting priveleges to user."
							ssh root@$TARGET_IP "$SQL_COMMAND -e \"GRANT ALL PRIVILEGES on \\\`$DBNAME\\\`.* to \\\`$DBUSER\\\`@localhost IDENTIFIED BY \\\"$DBPASS\\\"\""
							echo_result
							echo -e "-----"
				                ;;
				                * )
				                        echo -e "$MSG_ERR: We couldn't detect supported panel on target, and OS seems to be not Debian-based. Sorry."
				                        SQL_COMMAND="exit 1 #"
				                ;;
				        esac
				else
				# Request for overwriting DB
					echo -e "$MSG_ERR: DB $DBNAME already exists! We can destroy data in it!"
					PROMPT=0
					read -p "Are you sure you want to continue? [y/N] " answer
					case ${answer:0:1} in
					    y|Y )
					        echo -e "INFO: OK, let,s go!"
					        PROMPT=1
					    ;;
					    * )
					        echo -e "INFO: Skipping DB $DBNAME."
					        PROMPT=0
					        continue
					    ;;
					esac
					if [ $PROMPT -eq 0 ]; then
						echo -e "$MSG_ERR: You wasn't meant to see that!. Exiting now!"
						exit 1
					fi
				fi


				echo -e "INFO: Uploading dump to DB $DBNAME ($TXT_YLW ssh root@$TARGET_IP "mysql -u$DBUSER -p$DBPASS $DBNAME" < $DUMP_FILE $TXT_RST)"
				ssh root@$TARGET_IP "mysql -u$DBUSER -p$DBPASS $DBNAME" < $DUMP_FILE
				echo_result
				echo -e "-----"
			done
		;;
		* )
			echo -e "$MSG_ERR: Wrong mysql_dump mode! Exiting now!"
			exit 1
		;;
	esac 
}

# Function to detect panel and select MySQL connection type
function panel_detect {
	echo -e "INFO: Detecting panel."

	PANEL_CHECK_RESULT=`ssh root@$TARGET_IP 'if [ -f /etc/mysql/password ]; then printf 'FastPanel::'; cat /etc/mysql/password; else if [ -f /usr/local/ispmgr/etc/ispmgr.conf ]; then printf 'ISPmanager4::'; grep -E "\bPassword" /usr/local/ispmgr/etc/ispmgr.conf | awk '{print\\\\\\$2}'; else if [ -f /root/.my.cnf ]; then printf 'ISPmanager5::'; grep 'password' /root/.my.cnf | awk '{print\\\\\\$3}'; else if [ -f /etc/mysql/debian.cnf ]; then echo 'Debian::system'; fi; fi; fi; fi'`
	echo_result
	
	PANEL=`echo $PANEL_CHECK_RESULT | awk -F:: '{print $1}'`
	SQL_PASS=`echo $PANEL_CHECK_RESULT | awk -F"$PANEL::" '{print $2}'`

	case $PANEL in
		FastPanel )
			echo -e "INFO: We have ${TXT_YLW}FastPanel${TXT_RST} on target. Using password from ${TXT_YLW}/etc/mysql/password${TXT_RST}"
			SQL_COMMAND="mysql -uroot -p$SQL_PASS"
		;;
		ISPmanager4 )
			echo -e "INFO: We have ${TXT_YLW}ISPmanager 4${TXT_RST} on target. Using password from ${TXT_YLW}/usr/local/ispmgr/etc/ispmgr.conf${TXT_RST}"
			echo -e "Password is $SQL_PASS"
			SQL_COMMAND="mysql -uroot -p$SQL_PASS"
		;;
		ISPmanager5 )
			echo -e "INFO: We have ${TXT_YLW}ISPmanager 5${TXT_RST} on target. Using password from ${TXT_YLW}/usr/local/mgr5/etc/ispmgr.db${TXT_RST}"
			SQL_COMMAND="mysql -uroot -p$SQL_PASS"
		;;
		Debian )
			echo -e "$MSG_WRN: We couldn't detect supported panel on target, but we can use ${TXT_YLW}Debian${TXT_RST} system credentials from ${TXT_YLW}/etc/mysql/debian.cnf${TXT_RST}"
			SQL_COMMAND="mysql --defaults-file=/etc/mysql/debian.cnf"
		;;
		* )
			echo -e "$MSG_ERR: We couldn't detect supported panel on target, and OS seems to be not Debian-based. Sorry."
			SQL_COMMAND="exit 1 #"
		;;
	esac
}

# Checking if we really can access MySQL on target
function mysql_check {
	echo -e "INFO: Perfoming MySQL access check on remote host."
	if [ "$SQL_PASS" == "" ]; then 
		echo -e "$MSG_ERR: We don't have MySQL password!"
	else
		ssh root@$TARGET_IP "$SQL_COMMAND -e 'exit'"
		echo_result
	fi
		
}

# CMS detection and DB dumping
ERR_CNT=0
UNKNOWN_CMS=()
UNKNOWN_CMS_CNT=0
UNEXIST_DIR=()
UNEXIST_DIR_CNT=0
DB_ARRAY=()
COUNTER=0
echo -e "=========="
echo -e "Site transfer sript starting"
echo -e "=========="
for SITE_DIR in ${SITES[@]}; do
	REMOTE_USER=${REM_USERS[$COUNTER]}
	((COUNTER++))
	# Check for existance
	if [ ! -d ${SITE_DIR} ]; then
		echo -e "$MSG_ERR: directory $SITE_DIR does not exist!"
		UNEXIST_DIR+=($SITE_DIR)
		((UNEXIST_DIR_CNT++))
		((ERR_CNT++))
		echo -e "-----"
		continue
	fi
	# CMS detection
	CMS_DETECTED=0
	for i  in ${CMS_ARR[@]}; do 
		CMS=`echo $i | awk -F:: '{print $1}'`
		FILE=`echo $i | awk -F:: '{print $2}'`
		TYPE=`echo $i | awk -F:: '{print $3}'`
		if [ -f ${SITE_DIR}$FILE ]; then
			echo -e "INFO: ${TXT_YLW}${CMS}${TXT_RST} at ${SITE_DIR}"
			CMS_DETECTED=1

			### Dump database
			# Getting DB credentials from CMS list
			DBNAME_STR=`echo $i | awk -F:: '{print $4}'`
			DBUSER_STR=`echo $i | awk -F:: '{print $5}'`
			DBPASS_STR=`echo $i | awk -F:: '{print $6}'`
			DBHOST_STR=`echo $i | awk -F:: '{print $7}'`

			# Parse DB credentials from config
			echo -e "INFO: Parsing ${SITE_DIR}$FILE "
			# For case with multiple strings
			if [ $TYPE == 'var' ]; then
				DBNAME=(`grep -E "$DBNAME_STR" ${SITE_DIR}$FILE | sed -re "s/$DBNAME_STR//" | awk -F[]\'\"] '{print $1}'`)
				DBUSER=(`grep -E "$DBUSER_STR" ${SITE_DIR}$FILE | sed -re "s/$DBUSER_STR//" | awk -F[]\'\"] '{print $1}'`)
				DBPASS=(`grep -E "$DBPASS_STR" ${SITE_DIR}$FILE | sed -re "s/$DBPASS_STR//" | awk -F[]\'\"] '{print $1}'`)
				DBHOST=(`grep -E "$DBHOST_STR" ${SITE_DIR}$FILE | sed -re "s/$DBHOST_STR//" | awk -F[]\'\"] '{print $1}'`)
			fi
			echo_result
			
			# Creating dump to temp_dir
			mysql_dump dump

			# Checking dump
			mysql_dump check
			
			# We've detected CMS! Break from loop.
			echo -e "-----"
			break
		fi

	done
	if [ $CMS_DETECTED -eq 0 ]; then
		echo -e "$MSG_WRN: CMS is ${TXT_RED}unknown${TXT_RST} for $SITE_DIR"
		UNKNOWN_CMS+=(${SITE_DIR})
		((UNKNOWN_CMS_CNT++))
		echo -e "-----"
	fi
done

echo -e "=========="
echo -e "Check this report before you continue!"
echo -e "=========="

# Errors report
if [ $ERR_CNT -eq 0 ]; then
	echo -e "INFO: Databases for all detected CMS dumped. Everything seems ${MSG_OK}."
	echo -e "-----"
else
	echo -e "$MSG_ERR: There are $ERR_CNT errors!"
	echo -e "-----"
fi

# Unknown CMS report
if [ $UNKNOWN_CMS_CNT -eq 0 ]; then
	echo -e "INFO: All CMS detected!"
	echo -e "-----"
else
	echo -e "$MSG_WRN: $UNKNOWN_CMS_CNT CMS not detected. We'll transfer data, but you need to check databases. Sites:"
	for site in ${UNKNOWN_CMS[*]}; do
		echo -e "$site"
	done
	echo -e "-----"
fi

# Non-existing directore reporting
if [ $UNEXIST_DIR_CNT -gt 0 ]; then
	echo -e "$MSG_ERR: $UNEXIST_DIR_CNT directories do not exist. We'll not transfer them. Dirs:"
	for dir in ${UNEXIST_DIR[*]}; do
		echo -e "$dir"
	done
	echo -e "-----"
fi

echo -e "=========="

# Exit if no target specified
#echo -e "DEBUG: $
if [ "$TARGET_IP" == "" ]; then 
	echo -e "$MSG_WRN: You did not specified target IP. Exiting now."
	exit 0
fi

# Request Y to continue with transferring data
PROMPT=0
read -p "Continue with transferring data? [y/N] " answer
case ${answer:0:1} in
    y|Y )
        echo -e "OK, let,s go!"
	PROMPT=1	
    ;;
    * )
        echo -e 'Stopping.'
	PROMPT=0	
	exit 1
    ;;
esac

if [ $PROMPT -eq 0 ]; then
	echo -e "$MSG_ERR: You wasn't meant to see that!. Exiting now!"
	exit 1
fi

## Making sure we can connect to target
# Creating SSH key if needed
if [ ! -f ~/.ssh/id_rsa.pub ]; then
	echo -e "INFO: Creating SSH key"
	ssh-keygen -t rsa -q -f ~/.ssh/id_rsa -P ""
	echo_result
fi

# Testing SSH connection
echo -e "INFO: Testing SSH connection to ${TXT_YLW}${TARGET_IP}${TXT_RST}"
SSH_KEY=0
ssh -o 'PasswordAuthentication no'  root@$TARGET_IP 'exit'
if [ `echo $?` -eq 0 ]; then
        echo -e "INFO: [$MSG_OK]"
else
        echo -e "INFO: We couldn't connect to target."
	# Putting key to target
	echo -e "INFO: Putting key to target. You'll be asked for password."
	ssh-copy-id -i ~/.ssh/id_rsa.pub root@$TARGET_IP
	{
	        if [ `echo $?` -eq 0 ]; then
	                echo -e "INFO: [$MSG_OK]"
			SSH_KEY=1
	        else
	                echo -e "$MSG_ERR: Failed!"
	        fi
	}
fi

# Check rsync
RSYNC=1
if [ `ssh root@$TARGET_IP 'which rsync >/dev/null; echo $?'` == 1 ]; then
	echo -en "$MSG_ERR: We don't have rsync on target. Still upload dumps?"	
	PROMPT=0
	read -p "[y/N] " answer
        case ${answer:0:1} in
            y|Y )
                echo -e "OK, let,s go!"
                PROMPT=1
		RSYNC=0
            ;;
            * )
                echo -e 'Exiting now.'
		PROMPT=0
		exit 1
            ;;
        esac
else
        if [ $PROMPT -eq 0 ]; then
                echo -e "$MSG_ERR: You wasn't meant to see that!. Exiting now!"
                exit 1
        fi
fi

# Creating  databases and loading dumps on target

panel_detect
echo -e "=========="
create_domains
echo -e "=========="

if [ "$SQL_COMMAND" == "exit 1 #" ]; then
	echo -e "INFO: No MySQL root password - no database creation. But we can try to upload dump, if you are sure everything will be OK."
	# Request Y to continue with uploading dumps
	PROMPT=0
	read -p "Continue with uploading dumps? [y/N] " answer
	case ${answer:0:1} in
	    y|Y )
	        echo -e "OK, let,s go!"
	        PROMPT=1
		echo -e "=========="
		echo -e "Uploading dumps to target"
		echo -e "=========="
		mysql_dump restore 
	    ;;
	    * )
	        echo -e 'Skipping uploading dumps.'
	        PROMPT=0
	    ;;
	esac
else 
	if [ $PROMPT -eq 0 ]; then
	        echo -e "$MSG_ERR: You wasn't meant to see that!. Exiting now!"
	        exit 1
	fi
	mysql_check
	echo -e "=========="
	echo -e "Uploading dumps to target"
	echo -e "=========="
	mysql_dump restore 
	echo -e "=========="
fi


# Transferring data with rsync
if [ $RSYNC == 1 ]; then
	echo -e "Now we'll rsync data to target!"
	echo -e "=========="
	for ((i=0; i<${#SITES[@]}; i++)); do
	        if [ ! -d ${SITES[$i]} ]; then
	                echo -e "$MSG_ERR: directory ${SITES[$i]} does not exist! Skipping."
	                echo -e "-----"
	                continue
	        fi
		
		echo -e "INFO: Starting rsync of ${SITES[$i]}"
		echo -e "INFO:$TXT_YLW rsync -azH --numeric-ids --log-file=rsync-$i.log ${SITES[$i]} root@$TARGET_IP:${TARGETS[$i]} $TXT_RST"
		rsync -azH --numeric-ids --log-file=rsync-$i.log ${SITES[$i]} root@$TARGET_IP:${TARGETS[$i]}
		echo_result
		echo -e "INFO: Changing owner of files to ${REM_USERS[$i]}:${REM_USERS[$i]}"
		ssh root@$TARGET_IP "chown -R ${REM_USERS[$i]}:${REM_USERS[$i]} ${TARGETS[$i]}"
		echo_result
		echo -e "-----"
	done
	if [ $SSH_KEY == 1 ]; then
		echo -e "INFO: Removing key from target"
		PUB_KEY=`cat ~/.ssh/id_rsa.pub`
		ssh root@$TARGET_IP "sed -ie 's|$PUB_KEY||' ~/.ssh/authorized_keys"
		echo_result
	fi
else
	echo -e "INFO: No rsync. That's all."
fi
