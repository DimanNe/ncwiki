set -l this_dir (dirname (realpath (status current-filename)))
source $this_dir/util.fish
source $this_dir/zstd.fish

#
# These helpers deploy NextCloud from the community version (https://github.com/nextcloud/docker)
# (as opposed to the official docker-compose)
#


set NC_REMOTE_SSH TODO                              # Remote SSH server
set NC_REMOTE_DIR $HOME/nextcloud                   # where all files related to nextcloud installaltion will be
set NC_LOCAL      $HOME/devel/scripts/man/nextcloud # Local directory
set NC_BACKUP     /TODO/NextCloud                   # Local directory with backup


# ========================================================================================


# Remote locations:
set nc_dir__pproxy_keys  $NC_REMOTE_DIR/keys
set nc_vol__nc           $NC_REMOTE_DIR/volume-nc
set nc_vol__db           $NC_REMOTE_DIR/volume-db
set nc_dir__compose      $NC_REMOTE_DIR/compose
set nc_img_dir__nc       $NC_REMOTE_DIR/image-nextcloud
set nc_img_dir__pproxy   $NC_REMOTE_DIR/image-pproxy
set nc_owner             www-data


function nc-bootstrap
   argparse --ignore-unknown "dir=" -- $argv || return
   RunVerbosely ssh $NC_REMOTE_SSH 'sudo apt update && sudo apt install -y docker.io docker-buildx docker-compose && sudo usermod -a -G docker (whoami)'
   RunVerbosely ssh $NC_REMOTE_SSH mkdir -p $nc_dir__pproxy_keys
   if not set -q _flag_dir
      echo -e "You have to provide path to directory where keys generated by $BGray""yu-pki-generate-keypair-and-cert-server --serial 15430299 --host asdf.qwer --host zxcv.qwer --ip 127.0.0.1 --dump-private-key"$Color_Off" can be found"
      return
   end
   scp $_flag_dir/CA.crt.pem $_flag_dir/server-cert.pem $_flag_dir/server-key.pem $NC_REMOTE_SSH:$nc_dir__pproxy_keys
end

function nc_impl_rsync_del
   string split ' ' --  rsync --mkpath --checksum --recursive --compress --compress-choice zstd --compress-level 13 --verbose --itemize-changes --progress --stats --perms --owner --group --times --omit-dir-times --delete --copy-links
end



function nc-deploy
   if not ssh $NC_REMOTE_SSH test -d $nc_dir__pproxy_keys
      echo "$nc_dir__pproxy_keys on $NC_REMOTE_SSH must exists and should be populated. Use nc-bootstrap first!"
   end

   set nc_loc_img_dir__nc    $NC_LOCAL/community/28/apache
   set nc_loc_dir__compose   $NC_LOCAL/compose
   set nc_loc_dir__pproxy    $NC_LOCAL/pproxy

   cat $nc_loc_dir__compose/.env-static > $nc_loc_dir__compose/.env
   echo "
NC_DIR__PPROXY_KEYS=$nc_dir__pproxy_keys
NC_VOL__NC=$nc_vol__nc
NC_VOL__DB=$nc_vol__db
NC_IMG_DIR__NC=$nc_img_dir__nc
NC_IMG_DIR__PPROXY=$nc_img_dir__pproxy
" >> $nc_loc_dir__compose/.env

   nc-stop

   echo -e "\n"$Yellow"Copying compose, pproxy and nextcloud to $NC_REMOTE_SSH"$Color_Off
   RunVerbosely (nc_impl_rsync_del) $nc_loc_dir__compose                  $NC_REMOTE_SSH:$NC_REMOTE_DIR
   RunVerbosely (nc_impl_rsync_del) $nc_loc_dir__pproxy/ --exclude target $NC_REMOTE_SSH:$nc_img_dir__pproxy
   RunVerbosely (nc_impl_rsync_del) $nc_loc_img_dir__nc/                  $NC_REMOTE_SSH:$nc_img_dir__nc
   RunVerbosely ssh $NC_REMOTE_SSH mkdir -p $nc_vol__nc $nc_vol__db

   RunVerbosely ssh $NC_REMOTE_SSH "cd $nc_dir__compose && docker-compose build --parallel"

   echo -e "\n"$Yellow"Done. Start it manually first time: "$Gray"nc-start"$Color_Off" wait until it is initialises itself"
   echo -e $Yellow"And then initialise via: "$Gray"nc-init"$Color_Off" or "$Gray"nc-init-from-afresh"$Color_Off" or "$Gray"nc-init-from-backup"
end


function nc-start
   echo -e "\n"$Yellow"Starting nextcloud..."$Color_Off
   RunVerbosely ssh $NC_REMOTE_SSH "cd $nc_dir__compose && docker-compose up -d"
   RunVerbosely ssh $NC_REMOTE_SSH "cd $nc_dir__compose && docker-compose logs -f"
end

function nc-stop
   RunVerbosely ssh -t $NC_REMOTE_SSH "cd $nc_dir__compose && docker-compose stop && docker container prune -f && docker-compose down"
end




function nc-init
   echo -e "\n"$Yellow"Initialising NextCloud (installing apps)"$Color_Off
   # Nextcloud has some stupid rate-limits for number of calendars created:
   # https://docs.nextcloud.com/server/28/admin_manual/groupware/calendar.html#rate-limits
   # adjust them here too:
   RunVerbosely ssh $NC_REMOTE_SSH docker exec --user $nc_owner nextcloud "bash -c '\
      php occ app:install tasks;             \
      php occ app:install calendar;          \
      php occ app:install deck;              \
      php occ app:install contacts;          \
      php occ app:install circles;           \
      php occ app:install camerarawpreviews; \
      php occ config:app:set dav rateLimitCalendarCreation --value=8192
      php occ config:app:set dav maximumCalendarsSubscriptions --value=-1
      '"
end

function nc-init-from-afresh
   nc-init
   echo -e "\n"$Yellow"Initialising NextCloud (creating users)"$Color_Off
   set -l pass (date +%d.%m.%Y.%H)
   RunVerbosely ssh -t $NC_REMOTE_SSH docker exec --user $nc_owner -it nextcloud bash -c "\" \
      export OC_PASS=$pass;                                                                  \
      php occ user:add --password-from-env --no-interaction TODO;                         \
      php occ user:add --password-from-env --no-interaction TODO;                         \
      php occ user:add --password-from-env --no-interaction TODO;                          \
      \""
end


# set -l nc_mariadb_db_name nextcloud
function nc-backup
   set prev_ver_dir $NC_BACKUP/(date -u +%Y.%m.%d--%H:%M:%S)
   set curr_ver_dir $NC_BACKUP/latest
   if test -d "$curr_ver_dir"
      echo -e "\n"$Yellow"Copying latest to $prev_ver_dir..."$Color_Off
      # cp -r $curr_ver_dir $prev_ver_dir
      compress-dir -d $curr_ver_dir -f $prev_ver_dir.tar.zst -c 22
   end

   nc-stop
   echo -e "\n"$Yellow"Syncing data dir..."$Color_Off
   RunVerbosely (nc_impl_rsync_del) $NC_REMOTE_SSH:$nc_vol__nc/data $curr_ver_dir

   echo -e "\n"$Yellow"Syncing DB..."$Color_Off
   RunVerbosely ssh $NC_REMOTE_SSH "cd $nc_dir__compose && docker-compose up -d db && ./wait-mariadb.fish && \
      docker exec db sh -c 'mariadb-dump -uroot -p\"\$MARIADB_ROOT_PASSWORD\" nextcloud' > /tmp/db.dump"
   RunVerbosely (nc_impl_rsync_del) $NC_REMOTE_SSH:/tmp/db.dump $curr_ver_dir
   RunVerbosely ssh $NC_REMOTE_SSH "rm /tmp/db.dump"

   echo -e "\n"$Yellow"Done. Starting Nextcloud instance..."$Color_Off
   RunVerbosely ssh $NC_REMOTE_SSH "cd $nc_dir__compose && docker-compose up -d"
end

function nc-init-from-backup
   # nc-init
   nc-stop
   set curr_ver_dir $NC_BACKUP/latest
   echo -e "\n"$Yellow"Restoring data dir..."$Color_Off
   RunVerbosely ssh $NC_REMOTE_SSH "sudo chown -R (whoami):(whoami) $nc_vol__nc/data"
   RunVerbosely (nc_impl_rsync_del) $curr_ver_dir/data $NC_REMOTE_SSH:$nc_vol__nc/
   RunVerbosely ssh $NC_REMOTE_SSH "sudo chown -R www-data:www-data $nc_vol__nc/data"

   echo -e "\n"$Yellow"Restoring DB..."$Color_Off
   RunVerbosely (nc_impl_rsync_del) $curr_ver_dir/db.dump $NC_REMOTE_SSH:/tmp/db.dump
   RunVerbosely ssh $NC_REMOTE_SSH "cd $nc_dir__compose && docker-compose up -d db && ./wait-mariadb.fish && \
      docker exec -i db sh -c 'exec mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" nextcloud' < /tmp/db.dump && \
      rm /tmp/db.dump"

   echo -e "\n"$Yellow"Done. Starting Nextcloud instance..."$Color_Off
   RunVerbosely ssh $NC_REMOTE_SSH "cd $nc_dir__compose && docker-compose up -d"
end



function nc-eradicate
   RunVerbosely ssh -t $NC_REMOTE_SSH "cd $nc_dir__compose && docker-compose kill && docker-compose down && \
         docker volume rm (docker volume ls | rg 'local +(nextcloud_.*)' -or '\$1'); \
         sudo rm -rf $nc_vol__nc $nc_vol__db"
end
