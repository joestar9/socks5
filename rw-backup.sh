#!/bin/bash

set -e

VERSION="2.2.0"
INSTALL_DIR="/opt/rw-backup-restore"
BACKUP_DIR="$INSTALL_DIR/backup"
CONFIG_FILE="$INSTALL_DIR/config.env"
CUSTOM_DIRS_FILE="$INSTALL_DIR/custom_dirs.list"
SCRIPT_NAME="backup-restore.sh"
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"
RETAIN_BACKUPS_DAYS=7
SYMLINK_PATH="/usr/local/bin/rw-backup"
REMNALABS_ROOT_DIR=""
ENV_NODE_FILE=".env-node"
ENV_FILE=".env"
SCRIPT_REPO_URL="https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/rw-backup.sh"
SCRIPT_RUN_PATH="$(realpath "$0")"
GD_CLIENT_ID=""
GD_CLIENT_SECRET=""
GD_REFRESH_TOKEN=""
GD_FOLDER_ID=""
UPLOAD_METHOD="telegram"
CRON_TIMES=""
TG_MESSAGE_THREAD_ID=""
UPDATE_AVAILABLE=false
BACKUP_EXCLUDE_PATTERNS="*.log *.tmp .git"

BOT_BACKUP_ENABLED="false"
BOT_BACKUP_PATH=""
BOT_BACKUP_SELECTED=""
BOT_BACKUP_DB_USER="postgres"


if [[ -t 0 ]]; then
    RED=$'\e[31m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    GRAY=$'\e[37m'
    LIGHT_GRAY=$'\e[90m'
    CYAN=$'\e[36m'
    RESET=$'\e[0m'
    BOLD=$'\e[1m'
else
    RED=""
    GREEN=""
    YELLOW=""
    GRAY=""
    LIGHT_GRAY=""
    CYAN=""
    RESET=""
    BOLD=""
fi

print_message() {
    local type="$1"
    local message="$2"
    local color_code="$RESET"

    case "$type" in
        "INFO") color_code="$GRAY" ;;
        "SUCCESS") color_code="$GREEN" ;;
        "WARN") color_code="$YELLOW" ;;
        "ERROR") color_code="$RED" ;;
        "ACTION") color_code="$CYAN" ;;
        "LINK") color_code="$CYAN" ;;
        *) type="INFO" ;;
    esac

    echo -e "${color_code}[$type]${RESET} $message"
}

setup_symlink() {
    echo ""
    if [[ "$EUID" -ne 0 ]]; then
        print_message "WARN" "Root privileges are required to manage the symlink ${BOLD}${SYMLINK_PATH}${RESET}. Skipping setup."
        return 1
    fi

    if [[ -L "$SYMLINK_PATH" && "$(readlink -f "$SYMLINK_PATH")" == "$SCRIPT_PATH" ]]; then
        print_message "SUCCESS" "Symlink ${BOLD}${SYMLINK_PATH}${RESET} is already set and points to ${BOLD}${SCRIPT_PATH}${RESET}."
        return 0
    fi

    print_message "INFO" "Creating or updating symlink ${BOLD}${SYMLINK_PATH}${RESET}..."
    rm -f "$SYMLINK_PATH"
    if [[ -d "$(dirname "$SYMLINK_PATH")" ]]; then
        if ln -s "$SCRIPT_PATH" "$SYMLINK_PATH"; then
            print_message "SUCCESS" "Symlink ${BOLD}${SYMLINK_PATH}${RESET} successfully configured."
        else
            print_message "ERROR" "Failed to create symlink ${BOLD}${SYMLINK_PATH}${RESET}. Check permissions."
            return 1
        fi
    else
        print_message "ERROR" "Directory ${BOLD}$(dirname "$SYMLINK_PATH")${RESET} not found. Symlink not created."
        return 1
    fi
    echo ""
    return 0
}

manage_custom_dirs() {
    while true; do
        clear
        echo -e "${GREEN}${BOLD}Manage Additional Directories${RESET}"
        echo ""
        echo "Here you can add unlimited custom directories to include in the backup."
        echo ""
        
        if [[ -f "$CUSTOM_DIRS_FILE" && -s "$CUSTOM_DIRS_FILE" ]]; then
            echo -e "${BOLD}Current Custom Directories:${RESET}"
            local i=1
            while IFS= read -r line; do
                echo " $i. $line"
                ((i++))
            done < "$CUSTOM_DIRS_FILE"
        else
            echo -e "${GRAY}No custom directories added yet.${RESET}"
        fi
        
        echo ""
        echo " 1. Add Directory"
        echo " 2. Remove Directory"
        echo ""
        echo " 0. Back to Main Menu"
        echo ""
        
        read -rp "${GREEN}[?]${RESET} Select an option: " choice
        echo ""
        
        case $choice in
            1)
                print_message "ACTION" "Enter the absolute path of the directory to add:"
                read -rp " Path: " new_dir
                
                if [[ -z "$new_dir" ]]; then
                    print_message "ERROR" "Path cannot be empty."
                elif [[ ! "$new_dir" = /* ]]; then
                    print_message "ERROR" "Path must be absolute (start with /)."
                elif [[ ! -d "$new_dir" ]]; then
                    print_message "WARN" "Directory does not exist on disk currently. Add anyway? (y/n)"
                    read -r confirm_add
                    if [[ "$confirm_add" =~ ^[yY]$ ]]; then
                        echo "$new_dir" >> "$CUSTOM_DIRS_FILE"
                        print_message "SUCCESS" "Directory added."
                    fi
                else
                    # Check if already exists
                    if grep -Fxq "$new_dir" "$CUSTOM_DIRS_FILE" 2>/dev/null; then
                         print_message "WARN" "Directory is already in the list."
                    else
                         echo "$new_dir" >> "$CUSTOM_DIRS_FILE"
                         print_message "SUCCESS" "Directory added."
                    fi
                fi
                ;;
            2)
                if [[ ! -f "$CUSTOM_DIRS_FILE" || ! -s "$CUSTOM_DIRS_FILE" ]]; then
                    print_message "WARN" "List is empty."
                    read -rp "Press Enter to continue..."
                    continue
                fi
                
                print_message "ACTION" "Enter the number of the directory to remove:"
                read -rp " Number: " del_num
                
                if [[ "$del_num" =~ ^[0-9]+$ ]]; then
                    # Use sed to delete line number, verifying it exists
                    local total_lines=$(wc -l < "$CUSTOM_DIRS_FILE")
                    if (( del_num > 0 && del_num <= total_lines )); then
                        sed -i "${del_num}d" "$CUSTOM_DIRS_FILE"
                        print_message "SUCCESS" "Directory removed."
                    else
                        print_message "ERROR" "Invalid number."
                    fi
                else
                    print_message "ERROR" "Invalid input."
                fi
                ;;
            0)
                break
                ;;
            *)
                print_message "ERROR" "Invalid selection."
                ;;
        esac
        echo ""
        read -rp "Press Enter to continue..."
    done
}

configure_bot_backup() {
    while true; do
        clear
        echo -e "${GREEN}${BOLD}Telegram Bot Backup Configuration${RESET}"
        echo ""
        
        if [[ "$BOT_BACKUP_ENABLED" == "true" ]]; then
            print_message "INFO" "Bot Backup: ${BOLD}${GREEN}ENABLED${RESET}"
            print_message "INFO" "Selected Bot: ${BOLD}${BOT_BACKUP_SELECTED}${RESET}"
            print_message "INFO" "Bot Path: ${BOLD}${BOT_BACKUP_PATH}${RESET}"
        else
            print_message "INFO" "Bot Backup: ${BOLD}${RED}DISABLED${RESET}"
        fi
        
        echo ""
        echo " 1. Enable and configure bot backup"
        echo " 2. Disable bot backup"
        echo ""
        echo " 0. Back to Main Menu"
        echo ""
        
        read -rp "${GREEN}[?]${RESET} Select an option: " choice
        echo ""
        
        case $choice in
            1)
                clear
                echo -e "${GREEN}${BOLD}Telegram Bot Backup Configuration${RESET}"
                echo ""
                print_message "ACTION" "Select bot to backup:"
                echo " 1. Jesus's Bot (remnawave-telegram-shop)"
                echo " 2. Machka's Bot (remnawave-tg-shop)"
                echo ""
                echo " 0. Back"
                echo ""
                
                local bot_choice
                local selected_bot=""
                
                while true; do
                    read -rp " ${GREEN}[?]${RESET} Select bot: " bot_choice
                    case "$bot_choice" in
                        1)
                            selected_bot="Jesus's Bot"
                            break
                            ;;
                        2)
                            selected_bot="Machka's Bot"
                            break
                            ;;
                        0) 
                            selected_bot=""
                            break 
                            ;;
                        *)
                            print_message "ERROR" "Invalid input."
                            ;;
                    esac
                done
                
                if [[ -z "$selected_bot" ]]; then
                    continue
                fi
                
                BOT_BACKUP_SELECTED="$selected_bot"
                
                echo ""
                print_message "ACTION" "Select bot directory path:"
                if [[ "$BOT_BACKUP_SELECTED" == "Jesus's Bot" ]]; then
                    echo " 1. /opt/remnawave-telegram-shop"
                    echo " 2. /root/remnawave-telegram-shop"
                    echo " 3. /opt/stacks/remnawave-telegram-shop"
                else
                    echo " 1. /opt/remnawave-tg-shop"
                    echo " 2. /root/remnawave-tg-shop"
                    echo " 3. /opt/stacks/remnawave-tg-shop"
                fi
                echo " 4. Custom path"
                echo ""
                echo " 0. Back"
                echo ""

                local path_choice
                while true; do
                    read -rp " ${GREEN}[?]${RESET} Select path: " path_choice
                    case "$path_choice" in
                    1)
                        if [[ "$BOT_BACKUP_SELECTED" == "Jesus's Bot" ]]; then
                            BOT_BACKUP_PATH="/opt/remnawave-telegram-shop"
                        else
                            BOT_BACKUP_PATH="/opt/remnawave-tg-shop"
                        fi
                        break
                        ;;
                    2)
                        if [[ "$BOT_BACKUP_SELECTED" == "Jesus's Bot" ]]; then
                            BOT_BACKUP_PATH="/root/remnawave-telegram-shop"
                        else
                            BOT_BACKUP_PATH="/root/remnawave-tg-shop"
                        fi
                        break
                        ;;
                    3)
                        if [[ "$BOT_BACKUP_SELECTED" == "Jesus's Bot" ]]; then
                            BOT_BACKUP_PATH="/opt/stacks/remnawave-telegram-shop"
                        else
                            BOT_BACKUP_PATH="/opt/stacks/remnawave-tg-shop"
                        fi
                        break
                        ;;
                    4)
                        echo ""
                        print_message "INFO" "Enter full path to bot directory:"
                        read -rp " Path: " custom_bot_path
        
                        if [[ -z "$custom_bot_path" ]]; then
                            print_message "ERROR" "Path cannot be empty."
                            echo ""
                            read -rp "Press Enter to continue..."
                            continue
                        fi
        
                        if [[ ! "$custom_bot_path" = /* ]]; then
                            print_message "ERROR" "Path must be absolute (start with /)."
                            echo ""
                            read -rp "Press Enter to continue..."
                            continue
                        fi
        
                        custom_bot_path="${custom_bot_path%/}"
        
                        if [[ ! -d "$custom_bot_path" ]]; then
                            print_message "WARN" "Directory ${BOLD}${custom_bot_path}${RESET} does not exist."
                            read -rp "$(echo -e "${GREEN}[?]${RESET} Continue with this path? ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: ")" confirm_custom_bot_path
                            if [[ ! "$confirm_custom_bot_path" =~ ^[yY]$ ]]; then
                                echo ""
                                read -rp "Press Enter to continue..."
                                continue
                            fi
                        fi
        
                        BOT_BACKUP_PATH="$custom_bot_path"
                        print_message "SUCCESS" "Custom bot path set: ${BOLD}${BOT_BACKUP_PATH}${RESET}"
                        break
                        ;;
                    0)
                        continue 2
                        ;;
                    *)
                        print_message "ERROR" "Invalid input."
                        ;;
                    esac
                done
                
                echo ""
                read -rp " Enter PostgreSQL username for bot (default: postgres): " bot_db_user
                BOT_BACKUP_DB_USER="${bot_db_user:-postgres}"
                BOT_BACKUP_ENABLED="true"
                save_config
                print_message "SUCCESS" "Bot backup successfully configured and enabled."
                ;;
            2)
                BOT_BACKUP_ENABLED="false"
                BOT_BACKUP_PATH=""
                BOT_BACKUP_SELECTED=""
                save_config
                print_message "SUCCESS" "Bot backup disabled."
                ;;
            0) 
                break 
                ;;
            *) 
                print_message "ERROR" "Invalid input. Please select one of the options." 
                ;;
        esac
        
        echo ""
        read -rp "Press Enter to continue..."
    done
}

get_bot_params() {
    local bot_name="$1"
    
    case "$bot_name" in
        "Jesus's Bot")
            echo "remnawave-telegram-shop-db|remnawave-telegram-shop-db-data|remnawave-telegram-shop|db"
            ;;
        "Machka's Bot")
            echo "remnawave-tg-shop-db|remnawave-tg-shop-db-data|remnawave-tg-shop|remnawave-tg-shop-db"
            ;;
        *)
            echo "|||"
            ;;
    esac
}

create_bot_backup() {
    if [[ "$BOT_BACKUP_ENABLED" != "true" ]]; then
        return 0
    fi
    
    print_message "INFO" "Creating Telegram Bot backup: ${BOLD}${BOT_BACKUP_SELECTED}${RESET}..."
    
    local bot_params=$(get_bot_params "$BOT_BACKUP_SELECTED")
    IFS='|' read -r BOT_CONTAINER_NAME BOT_VOLUME_NAME BOT_DIR_NAME BOT_SERVICE_NAME <<< "$bot_params"
    
    if [[ -z "$BOT_CONTAINER_NAME" ]]; then
        print_message "ERROR" "Unknown bot: $BOT_BACKUP_SELECTED"
        print_message "INFO" "Continuing backup without bot..."
        return 0
    fi

    local BOT_BACKUP_FILE_DB="bot_dump_${TIMESTAMP}.sql.gz"
    local BOT_DIR_ARCHIVE="bot_dir_${TIMESTAMP}.tar.gz"
    
    if ! docker inspect "$BOT_CONTAINER_NAME" > /dev/null 2>&1 || ! docker container inspect -f '{{.State.Running}}' "$BOT_CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
        print_message "WARN" "Bot container '$BOT_CONTAINER_NAME' not found or not running. Skipping bot backup."
        return 0
    fi
    
    print_message "INFO" "Creating Bot PostgreSQL dump..."
    if ! docker exec -t "$BOT_CONTAINER_NAME" pg_dumpall -c -U "$BOT_BACKUP_DB_USER" | gzip -9 > "$BACKUP_DIR/$BOT_BACKUP_FILE_DB"; then
        print_message "ERROR" "Error creating Bot PostgreSQL dump. Continuing without bot backup..."
        return 0
    fi
    
    if [ -d "$BOT_BACKUP_PATH" ]; then
        print_message "INFO" "Archiving bot directory ${BOLD}${BOT_BACKUP_PATH}${RESET}..."
        local exclude_args=""
        for pattern in $BACKUP_EXCLUDE_PATTERNS; do
            exclude_args+="--exclude=$pattern "
        done
        
        if eval "tar -czf '$BACKUP_DIR/$BOT_DIR_ARCHIVE' $exclude_args -C '$(dirname "$BOT_BACKUP_PATH")' '$(basename "$BOT_BACKUP_PATH")'"; then
            print_message "SUCCESS" "Bot directory successfully archived."
        else
            print_message "ERROR" "Error archiving bot directory."
            return 1
        fi
    else
        print_message "WARN" "Bot directory ${BOLD}${BOT_BACKUP_PATH}${RESET} not found! Continuing without bot directory archive..."
        return 0
    fi
    
    BACKUP_ITEMS+=("$BOT_BACKUP_FILE_DB" "$BOT_DIR_ARCHIVE")
    
    print_message "SUCCESS" "Bot backup created successfully."
    echo ""
    return 0
}

restore_bot_backup() {
    local temp_restore_dir="$1"
    
    local BOT_DUMP_FILE=$(find "$temp_restore_dir" -name "bot_dump_*.sql.gz" | head -n 1)
    local BOT_DIR_ARCHIVE=$(find "$temp_restore_dir" -name "bot_dir_*.tar.gz" | head -n 1)
    
    if [[ -z "$BOT_DUMP_FILE" && -z "$BOT_DIR_ARCHIVE" ]]; then
        return 0
    fi

    clear
    print_message "INFO" "Telegram Bot backup found in archive."
    echo ""
    read -rp "$(echo -e "${GREEN}[?]${RESET} Restore Telegram Bot? ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: ")" restore_bot_confirm
    
    if [[ "$restore_bot_confirm" != "y" ]]; then
        print_message "INFO" "Bot restoration skipped."
        return 0
    fi
    
    echo ""
    print_message "ACTION" "Which bot was in the backup?"
    echo " 1. Jesus's Bot (remnawave-telegram-shop)"
    echo " 2. Machka's Bot (remnawave-tg-shop)"
    echo ""
    
    local bot_choice
    local selected_bot_name
    while true; do
        read -rp " ${GREEN}[?]${RESET} Select bot: " bot_choice
        case "$bot_choice" in
            1) selected_bot_name="Jesus's Bot"; break ;;
            2) selected_bot_name="Machka's Bot"; break ;;
            *) print_message "ERROR" "Invalid input." ;;
        esac
    done
    
    echo ""
    print_message "ACTION" "Select path to restore bot to:"
    if [[ "$selected_bot_name" == "Jesus's Bot" ]]; then
        echo " 1. /opt/remnawave-telegram-shop"
        echo " 2. /root/remnawave-telegram-shop"
        echo " 3. /opt/stacks/remnawave-telegram-shop"
    else
        echo " 1. /opt/remnawave-tg-shop"
        echo " 2. /root/remnawave-tg-shop"
        echo " 3. /opt/stacks/remnawave-tg-shop"
    fi
    echo " 4. Custom path"
    echo ""
    echo " 0. Back"
    echo ""

    local restore_path
    local path_choice
    while true; do
        read -rp " ${GREEN}[?]${RESET} Select path: " path_choice
        case "$path_choice" in
        1)
            if [[ "$selected_bot_name" == "Jesus's Bot" ]]; then
                restore_path="/opt/remnawave-telegram-shop"
            else
                restore_path="/opt/remnawave-tg-shop"
            fi
            break
            ;;
        2)
            if [[ "$selected_bot_name" == "Jesus's Bot" ]]; then
                restore_path="/root/remnawave-telegram-shop"
            else
                restore_path="/root/remnawave-tg-shop"
            fi
            break
            ;;
        3)
            if [[ "$selected_bot_name" == "Jesus's Bot" ]]; then
                restore_path="/opt/stacks/remnawave-telegram-shop"
            else
                restore_path="/opt/stacks/remnawave-tg-shop"
            fi
            break
            ;;
        4)
            echo ""
            print_message "INFO" "Enter full path for bot restoration:"
            read -rp " Path: " custom_restore_path
        
            if [[ -z "$custom_restore_path" ]]; then
                print_message "ERROR" "Path cannot be empty."
                echo ""
                read -rp "Press Enter to continue..."
                continue
            fi
        
            if [[ ! "$custom_restore_path" = /* ]]; then
                print_message "ERROR" "Path must be absolute (start with /)."
                echo ""
                read -rp "Press Enter to continue..."
                continue
            fi
        
            custom_restore_path="${custom_restore_path%/}"
            restore_path="$custom_restore_path"
            print_message "SUCCESS" "Custom restoration path set: ${BOLD}${restore_path}${RESET}"
            break
            ;;
        0)
            print_message "INFO" "Bot restoration cancelled."
            return 0
            ;;
        *)
            print_message "ERROR" "Invalid input."
            ;;
        esac
    done

    local bot_params=$(get_bot_params "$selected_bot_name")
    IFS='|' read -r BOT_CONTAINER_NAME BOT_VOLUME_NAME BOT_DIR_NAME BOT_SERVICE_NAME <<< "$bot_params"
    
    echo ""
    read -rp " Enter bot DB username (default: postgres): " restore_bot_db_user
    restore_bot_db_user="${restore_bot_db_user:-postgres}"
    echo ""
    read -rp "$(echo -e "${GREEN}[?]${RESET} Enter bot DB name (default: postgres): ")" restore_bot_db_name
    restore_bot_db_name="${restore_bot_db_name:-postgres}"
    echo ""
    print_message "INFO" "Starting Telegram Bot restoration..."
    
    if [[ -d "$restore_path" ]]; then
        print_message "INFO" "Directory ${BOLD}${restore_path}${RESET} exists. Stopping containers and cleaning..."
    
        if cd "$restore_path" 2>/dev/null && ([[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]); then
            print_message "INFO" "Stopping existing bot containers..."
            docker compose down 2>/dev/null || print_message "WARN" "Failed to stop containers (maybe they are already stopped)."
        else
            print_message "INFO" "Docker Compose file not found, skipping container stop."
        fi
    fi
        
    cd /
        
    print_message "INFO" "Removing old directory..."
    if [[ -d "$restore_path" ]]; then
        if ! rm -rf "$restore_path"; then
            print_message "ERROR" "Failed to remove directory ${BOLD}${restore_path}${RESET}."
            return 1
        fi
        print_message "SUCCESS" "Old directory removed."
    else
        print_message "INFO" "Directory ${BOLD}${restore_path}${RESET} does not exist. This is a fresh install."
    fi
    
    print_message "INFO" "Creating new directory..."
    if ! mkdir -p "$restore_path"; then
        print_message "ERROR" "Failed to create directory ${BOLD}${restore_path}${RESET}."
        return 1
    fi
    print_message "SUCCESS" "New directory created."
    echo ""
    
    if [[ -n "$BOT_DIR_ARCHIVE" ]]; then
        print_message "INFO" "Restoring bot directory from archive..."
        local temp_extract_dir="$BACKUP_DIR/bot_extract_temp_$$"
        mkdir -p "$temp_extract_dir"
        
        if tar -xzf "$BOT_DIR_ARCHIVE" -C "$temp_extract_dir"; then
            local extracted_dir=$(find "$temp_extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)

            if [[ -n "$extracted_dir" && -d "$extracted_dir" ]]; then
                if cp -rf "$extracted_dir"/. "$restore_path/" 2>/dev/null; then
                    print_message "SUCCESS" "Bot directory files restored (folder: $(basename "$extracted_dir"))."
                else
                    print_message "ERROR" "Error copying bot files."
                    rm -rf "$temp_extract_dir"
                    return 1
                fi
            else
                print_message "ERROR" "Failed to find directory with bot files in archive."
                rm -rf "$temp_extract_dir"
                return 1
            fi
        else
            print_message "ERROR" "Error unpacking bot directory archive."
            rm -rf "$temp_extract_dir"
            return 1
        fi
        rm -rf "$temp_extract_dir"
    else
        print_message "WARN" "Bot directory archive not found in backup."
        return 1
    fi
    
    print_message "INFO" "Checking and removing old DB volumes..."
    if docker volume ls -q | grep -Fxq "$BOT_VOLUME_NAME"; then
        local containers_using_volume
        containers_using_volume=$(docker ps -aq --filter volume="$BOT_VOLUME_NAME")
    
        if [[ -n "$containers_using_volume" ]]; then
            print_message "INFO" "Found containers using volume $BOT_VOLUME_NAME. Removing..."
            docker rm -f $containers_using_volume >/dev/null 2>&1
        fi
    
        if docker volume rm "$BOT_VOLUME_NAME" >/dev/null 2>&1; then
            print_message "SUCCESS" "Old DB volume $BOT_VOLUME_NAME removed."
        else
            print_message "WARN" "Failed to remove volume $BOT_VOLUME_NAME."
        fi
    else
        print_message "INFO" "No old DB volumes found."
    fi
    echo ""
    
    if ! cd "$restore_path"; then
        print_message "ERROR" "Failed to change to restored directory ${BOLD}${restore_path}${RESET}."
        return 1
    fi
    
    if [[ ! -f "docker-compose.yml" && ! -f "docker-compose.yaml" ]]; then
    print_message "ERROR" "docker-compose.yml or docker-compose.yaml not found in restored directory."
    return 1
    fi
    
    print_message "INFO" "Starting Bot DB container..."
    if ! docker compose up -d "$BOT_SERVICE_NAME"; then
        print_message "ERROR" "Failed to start Bot DB container."
        return 1
    fi
    
    echo ""
    print_message "INFO" "Waiting for Bot DB readiness..."
    local wait_count=0
    local max_wait=60
    
    until [ "$(docker inspect --format='{{.State.Health.Status}}' "$BOT_CONTAINER_NAME" 2>/dev/null)" == "healthy" ]; do
        sleep 2
        echo -n "."
        wait_count=$((wait_count + 1))
        if [ $wait_count -gt $max_wait ]; then
            echo ""
            print_message "ERROR" "Bot DB readiness timeout exceeded."
            return 1
        fi
    done
    echo ""
    print_message "SUCCESS" "Bot DB is ready."
    
    if [[ -n "$BOT_DUMP_FILE" ]]; then
        print_message "INFO" "Restoring Bot DB from dump..."
        local BOT_DUMP_UNCOMPRESSED="${BOT_DUMP_FILE%.gz}"
        
        if ! gunzip "$BOT_DUMP_FILE"; then
            print_message "ERROR" "Failed to decompress Bot DB dump."
            return 1
        fi
        
        mkdir -p "$temp_restore_dir"

        if ! docker exec -i "$BOT_CONTAINER_NAME" psql -q -U "$restore_bot_db_user" -d "$restore_bot_db_name" 2> "$temp_restore_dir/restore_errors.log" < "$BOT_DUMP_UNCOMPRESSED"; then
            print_message "ERROR" "Error restoring Bot DB."
            echo ""
            print_message "WARN" "${YELLOW}Restore error log:${RESET}"
            cat "$temp_restore_dir/restore_errors.log"
            [[ -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
            read -rp "Press Enter to return to menu..."
            return 1
        fi

        print_message "SUCCESS" "Bot DB successfully restored."
    else
        print_message "WARN" "Bot DB dump not found in archive."
    fi
    
    echo ""
    print_message "INFO" "Starting all bot containers..."
    if ! docker compose up -d; then
        print_message "ERROR" "Failed to start all bot containers."
        return 1
    fi
    
    sleep 3
    echo ""
    print_message "SUCCESS" "Telegram Bot successfully restored and started!"
    return 0
}

save_config() {
    print_message "INFO" "Saving configuration to ${BOLD}${CONFIG_FILE}${RESET}..."
    cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
DB_USER="$DB_USER"
UPLOAD_METHOD="$UPLOAD_METHOD"
GD_CLIENT_ID="$GD_CLIENT_ID"
GD_CLIENT_SECRET="$GD_CLIENT_SECRET"
GD_REFRESH_TOKEN="$GD_REFRESH_TOKEN"
GD_FOLDER_ID="$GD_FOLDER_ID"
CRON_TIMES="$CRON_TIMES"
REMNALABS_ROOT_DIR="$REMNALABS_ROOT_DIR"
TG_MESSAGE_THREAD_ID="$TG_MESSAGE_THREAD_ID"
BOT_BACKUP_ENABLED="$BOT_BACKUP_ENABLED"
BOT_BACKUP_PATH="$BOT_BACKUP_PATH"
BOT_BACKUP_SELECTED="$BOT_BACKUP_SELECTED"
BOT_BACKUP_DB_USER="$BOT_BACKUP_DB_USER"
EOF
    chmod 600 "$CONFIG_FILE" || { print_message "ERROR" "Failed to set permissions (600) for ${BOLD}${CONFIG_FILE}${RESET}. Check permissions."; exit 1; }
    print_message "SUCCESS" "Configuration saved."
}

load_or_create_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        print_message "INFO" "Loading configuration..."
        source "$CONFIG_FILE"
        echo ""

        UPLOAD_METHOD=${UPLOAD_METHOD:-telegram}
        DB_USER=${DB_USER:-postgres}
        CRON_TIMES=${CRON_TIMES:-}
        REMNALABS_ROOT_DIR=${REMNALABS_ROOT_DIR:-}
        TG_MESSAGE_THREAD_ID=${TG_MESSAGE_THREAD_ID:-}
        
        local config_updated=false

        if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
            print_message "WARN" "Required Telegram variables missing in configuration file."
            print_message "ACTION" "Please enter missing Telegram data (required):"
            echo ""
            print_message "INFO" "Create a Telegram bot via ${CYAN}@BotFather${RESET} and get the API Token"
            [[ -z "$BOT_TOKEN" ]] && read -rp "    Enter API Token: " BOT_TOKEN
            echo ""
            print_message "INFO" "Enter Chat ID (for group) or your Telegram ID (for direct bot messages)"
            echo -e "       You can find Chat ID/Telegram ID via this bot ${CYAN}@username_to_id_bot${RESET}"
            [[ -z "$CHAT_ID" ]] && read -rp "    Enter ID: " CHAT_ID
            echo ""
            print_message "INFO" "Optional: enter Message Thread ID for group topics"
            echo -e "       Leave empty for general chat or direct bot messages"
            read -rp "    Enter Message Thread ID: " TG_MESSAGE_THREAD_ID
            echo ""
            config_updated=true
        fi

        [[ -z "$DB_USER" ]] && read -rp "    Enter your DB username (default: postgres): " DB_USER
        DB_USER=${DB_USER:-postgres}
        config_updated=true
        echo ""
        
        if [[ -z "$REMNALABS_ROOT_DIR" ]]; then
            print_message "ACTION" "Where is your Remnawave panel installed?"
            echo " 1. /opt/remnawave"
            echo " 2. /root/remnawave"
            echo " 3. /opt/stacks/remnawave"
            echo " 4. Custom path"
            echo ""

            local remnawave_path_choice
            while true; do
                read -rp " ${GREEN}[?]${RESET} Select option: " remnawave_path_choice
                case "$remnawave_path_choice" in
                1) REMNALABS_ROOT_DIR="/opt/remnawave"; break ;;
                2) REMNALABS_ROOT_DIR="/root/remnawave"; break ;;
                3) REMNALABS_ROOT_DIR="/opt/stacks/remnawave"; break ;;
                4) 
                    echo ""
                    print_message "INFO" "Enter full path to Remnawave panel directory:"
                    read -rp " Path: " custom_remnawave_path
    
                    if [[ -z "$custom_remnawave_path" ]]; then
                        print_message "ERROR" "Path cannot be empty."
                        echo ""
                        read -rp "Press Enter to continue..."
                        continue
                    fi
    
                    if [[ ! "$custom_remnawave_path" = /* ]]; then
                        print_message "ERROR" "Path must be absolute (start with /)."
                        echo ""
                        read -rp "Press Enter to continue..."
                        continue
                    fi
    
                    custom_remnawave_path="${custom_remnawave_path%/}"
    
                    if [[ ! -d "$custom_remnawave_path" ]]; then
                        print_message "WARN" "Directory ${BOLD}${custom_remnawave_path}${RESET} does not exist."
                        read -rp "$(echo -e "${GREEN}[?]${RESET} Continue with this path? ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: ")" confirm_custom_path
                        if [[ "$confirm_custom_path" != "y" ]]; then
                            echo ""
                            read -rp "Press Enter to continue..."
                            continue
                        fi
                    fi
    
                    REMNALABS_ROOT_DIR="$custom_remnawave_path"
                    print_message "SUCCESS" "Custom path set: ${BOLD}${REMNALABS_ROOT_DIR}${RESET}"
                    break 
                    ;;
                *) print_message "ERROR" "Invalid input." ;;
                esac
            done

            config_updated=true
            echo ""
        fi

        if [[ "$UPLOAD_METHOD" == "google_drive" ]]; then
            if [[ -z "$GD_CLIENT_ID" || -z "$GD_CLIENT_SECRET" || -z "$GD_REFRESH_TOKEN" ]]; then
                print_message "WARN" "Incomplete Google Drive data found in configuration."
                print_message "WARN" "Upload method will be changed to ${BOLD}Telegram${RESET}."
                UPLOAD_METHOD="telegram"
                config_updated=true
            fi
        fi

        if [[ "$UPLOAD_METHOD" == "google_drive" && ( -z "$GD_CLIENT_ID" || -z "$GD_CLIENT_SECRET" || -z "$GD_REFRESH_TOKEN" ) ]]; then
            print_message "WARN" "Missing Google Drive variables in configuration."
            print_message "ACTION" "Please enter missing Google Drive data:"
            echo ""
            echo "If you don't have Client ID and Client Secret tokens"
            local guide_url="https://telegra.ph/Nastrojka-Google-API-06-02"
                print_message "LINK" "Read this guide: ${CYAN}${guide_url}${RESET}"
                echo ""
            [[ -z "$GD_CLIENT_ID" ]] && read -rp "    Enter Google Client ID: " GD_CLIENT_ID
            [[ -z "$GD_CLIENT_SECRET" ]] && read -rp "    Enter Google Client Secret: " GD_CLIENT_SECRET
            clear
            
            if [[ -z "$GD_REFRESH_TOKEN" ]]; then
                print_message "WARN" "Browser authorization is required to get Refresh Token."
                print_message "INFO" "Open the following link in your browser, authorize and copy the code:"
                echo ""
                local auth_url="https://accounts.google.com/o/oauth2/auth?client_id=${GD_CLIENT_ID}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=https://www.googleapis.com/auth/drive&response_type=code&access_type=offline"
                print_message "INFO" "${CYAN}${auth_url}${RESET}"
                echo ""
                read -rp "    Enter code from browser: " AUTH_CODE
                
                print_message "INFO" "Getting Refresh Token..."
                local token_response=$(curl -s -X POST https://oauth2.googleapis.com/token \
                    -d client_id="$GD_CLIENT_ID" \
                    -d client_secret="$GD_CLIENT_SECRET" \
                    -d code="$AUTH_CODE" \
                    -d redirect_uri="urn:ietf:wg:oauth:2.0:oob" \
                    -d grant_type="authorization_code")
                
                GD_REFRESH_TOKEN=$(echo "$token_response" | jq -r .refresh_token 2>/dev/null)
                
                if [[ -z "$GD_REFRESH_TOKEN" || "$GD_REFRESH_TOKEN" == "null" ]]; then
                    print_message "ERROR" "Failed to get Refresh Token. Check Client ID, Client Secret and the 'Code'."
                    print_message "WARN" "Google Drive setup not completed, upload method changed to ${BOLD}Telegram${RESET}."
                    UPLOAD_METHOD="telegram"
                    config_updated=true
                fi
            fi
            echo
                    echo "    📁 To specify Google Drive folder:"
                    echo "    1. Create and open the folder in browser."
                    echo "    2. Look at the URL, it looks like:"
                    echo "      https://drive.google.com/drive/folders/1a2B3cD4eFmNOPqRstuVwxYz"
                    echo "    3. Copy the part after /folders/ — this is the Folder ID."
                    echo "    4. If left empty — backup will be sent to root folder."
                    echo

                    read -rp "    Enter Google Drive Folder ID (leave empty for root): " GD_FOLDER_ID
            config_updated=true
        fi

        if $config_updated; then
            save_config
        else
            print_message "SUCCESS" "Configuration successfully loaded from ${BOLD}${CONFIG_FILE}${RESET}."
        fi

    else
        if [[ "$SCRIPT_RUN_PATH" != "$SCRIPT_PATH" ]]; then
            print_message "INFO" "Configuration not found. Script running from temporary location."
            print_message "INFO" "Moving script to installation directory: ${BOLD}${SCRIPT_PATH}${RESET}..."
            mkdir -p "$INSTALL_DIR" || { print_message "ERROR" "Failed to create install directory ${BOLD}${INSTALL_DIR}${RESET}. Check permissions."; exit 1; }
            mkdir -p "$BACKUP_DIR" || { print_message "ERROR" "Failed to create backup directory ${BOLD}${BACKUP_DIR}${RESET}. Check permissions."; exit 1; }

            if mv "$SCRIPT_RUN_PATH" "$SCRIPT_PATH"; then
                chmod +x "$SCRIPT_PATH"
                clear
                print_message "SUCCESS" "Script successfully moved to ${BOLD}${SCRIPT_PATH}${RESET}."
                print_message "ACTION" "Restarting script from new location to finish setup."
                exec "$SCRIPT_PATH" "$@"
                exit 0
            else
                print_message "ERROR" "Failed to move script to ${BOLD}${SCRIPT_PATH}${RESET}. Check permissions."
                exit 1
            fi
        else
            print_message "INFO" "Configuration not found, creating new..."
            echo ""
            print_message "INFO" "Create Telegram bot via ${CYAN}@BotFather${RESET} and get API Token"
            read -rp "    Enter API Token: " BOT_TOKEN
            echo ""
            print_message "INFO" "Enter Chat ID (for group) or your Telegram ID (for direct bot messages)"
            echo -e "       You can find Chat ID/Telegram ID via this bot ${CYAN}@username_to_id_bot${RESET}"
            read -rp "    Enter ID: " CHAT_ID
            echo ""
            print_message "INFO" "Optional: enter Message Thread ID for group topics"
            echo -e "       Leave empty for general chat or direct bot messages"
            read -rp "    Enter Message Thread ID: " TG_MESSAGE_THREAD_ID
            echo ""
            read -rp "    Enter PostgreSQL username (default: postgres): " DB_USER
            DB_USER=${DB_USER:-postgres}
            echo ""

            print_message "ACTION" "Where is your Remnawave panel installed?"
            echo " 1. /opt/remnawave"
            echo " 2. /root/remnawave"
            echo " 3. /opt/stacks/remnawave"
            echo " 4. Custom path"
            echo ""

            local remnawave_path_choice
            while true; do
                read -rp " ${GREEN}[?]${RESET} Select option: " remnawave_path_choice
                case "$remnawave_path_choice" in
                1) REMNALABS_ROOT_DIR="/opt/remnawave"; break ;;
                2) REMNALABS_ROOT_DIR="/root/remnawave"; break ;;
                3) REMNALABS_ROOT_DIR="/opt/stacks/remnawave"; break ;;
                4) 
                    echo ""
                    print_message "INFO" "Enter full path to Remnawave panel directory:"
                    read -rp " Path: " custom_remnawave_path
    
                    if [[ -z "$custom_remnawave_path" ]]; then
                        print_message "ERROR" "Path cannot be empty."
                        echo ""
                        read -rp "Press Enter to continue..."
                        continue
                    fi
    
                    if [[ ! "$custom_remnawave_path" = /* ]]; then
                        print_message "ERROR" "Path must be absolute (start with /)."
                        echo ""
                        read -rp "Press Enter to continue..."
                        continue
                    fi
    
                    custom_remnawave_path="${custom_remnawave_path%/}"
    
                    if [[ ! -d "$custom_remnawave_path" ]]; then
                        print_message "WARN" "Directory ${BOLD}${custom_remnawave_path}${RESET} does not exist."
                        read -rp "$(echo -e "${GREEN}[?]${RESET} Continue with this path? ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: ")" confirm_custom_path
                        if [[ "$confirm_custom_path" != "y" ]]; then
                            echo ""
                            read -rp "Press Enter to continue..."
                            continue
                        fi
                    fi
    
                    REMNALABS_ROOT_DIR="$custom_remnawave_path"
                    print_message "SUCCESS" "Custom path set: ${BOLD}${REMNALABS_ROOT_DIR}${RESET}"
                    break 
                    ;;
                *) print_message "ERROR" "Invalid input." ;;
                esac
            done
            echo ""

            mkdir -p "$INSTALL_DIR" || { print_message "ERROR" "Failed to create install directory ${BOLD}${INSTALL_DIR}${RESET}. Check permissions."; exit 1; }
            mkdir -p "$BACKUP_DIR" || { print_message "ERROR" "Failed to create backup directory ${BOLD}${BACKUP_DIR}${RESET}. Check permissions."; exit 1; }
            save_config
            print_message "SUCCESS" "New configuration saved to ${BOLD}${CONFIG_FILE}${RESET}"
        fi
    fi
    echo ""
}

escape_markdown_v2() {
    local text="$1"
    echo "$text" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/_/\\_/g' \
        -e 's/\[/\\[/g' \
        -e 's/\]/\\]/g' \
        -e 's/(/\\(/g' \
        -e 's/)/\\)/g' \
        -e 's/~/\~/g' \
        -e 's/`/\\`/g' \
        -e 's/>/\\>/g' \
        -e 's/#/\\#/g' \
        -e 's/+/\\+/g' \
        -e 's/-/\\-/g' \
        -e 's/=/\\=/g' \
        -e 's/|/\\|/g' \
        -e 's/{/\\{/g' \
        -e 's/}/\\}/g' \
        -e 's/\./\\./g' \
        -e 's/!/\!/g'
}

get_remnawave_version() {
    local version_output
    version_output=$(docker exec remnawave sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json
 2>/dev/null)
    if [[ -z "$version_output" ]]; then
        echo "unknown"
    else
        echo "$version_output"
    fi
}

send_telegram_message() {
    local message="$1"
    local parse_mode="${2:-MarkdownV2}"
    local escaped_message
    escaped_message=$(escape_markdown_v2 "$message")

    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        print_message "ERROR" "Telegram BOT_TOKEN or CHAT_ID not configured. Message not sent."
        return 1
    fi

    local url="https://api.telegram.org/bot$BOT_TOKEN/sendMessage"
    local data_params=(
        -d chat_id="$CHAT_ID"
        -d text="$escaped_message"
    )

    [[ -n "$parse_mode" ]] && data_params+=(-d parse_mode="$parse_mode")
    [[ -n "$TG_MESSAGE_THREAD_ID" ]] && data_params+=(-d message_thread_id="$TG_MESSAGE_THREAD_ID")

    local response
    response=$(curl -s -X POST "$url" "${data_params[@]}" -w "\n%{http_code}")
    local body=$(echo "$response" | head -n -1)
    local http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -eq 200 ]]; then
        return 0
    else
        echo -e "${RED}❌ Error sending Telegram message. Code: ${BOLD}$http_code${RESET}"
        echo -e "Telegram Response: ${body}"
        return 1
    fi
}

send_telegram_document() {
    local file_path="$1"
    local caption="$2"
    local parse_mode="MarkdownV2"
    local escaped_caption
    escaped_caption=$(escape_markdown_v2 "$caption")

    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        print_message "ERROR" "Telegram BOT_TOKEN or CHAT_ID not configured. Document not sent."
        return 1
    fi

    local form_params=(
        -F chat_id="$CHAT_ID"
        -F document=@"$file_path"
        -F parse_mode="$parse_mode"
        -F caption="$escaped_caption"
    )

    if [[ -n "$TG_MESSAGE_THREAD_ID" ]]; then
        form_params+=(-F message_thread_id="$TG_MESSAGE_THREAD_ID")
    fi

    local api_response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
        "${form_params[@]}" \
        -w "%{http_code}" -o /dev/null 2>&1)

    local curl_status=$?

    if [ $curl_status -ne 0 ]; then
        echo -e "${RED}❌ ${BOLD}CURL${RESET} error sending document to Telegram. Exit code: ${BOLD}$curl_status${RESET}. Check network connection.${RESET}"
        return 1
    fi

    local http_code="${api_response: -3}"

    if [[ "$http_code" == "200" ]]; then
        return 0
    else
        echo -e "${RED}❌ Telegram API returned HTTP error. Code: ${BOLD}$http_code${RESET}. Response: ${BOLD}$api_response${RESET}. Maybe file is too large or ${BOLD}BOT_TOKEN${RESET}/${BOLD}CHAT_ID${RESET} incorrect.${RESET}"
        return 1
    fi
}

get_google_access_token() {
    if [[ -z "$GD_CLIENT_ID" || -z "$GD_CLIENT_SECRET" || -z "$GD_REFRESH_TOKEN" ]]; then
        print_message "ERROR" "Google Drive Client ID, Client Secret or Refresh Token not configured."
        return 1
    fi

    local token_response=$(curl -s -X POST https://oauth2.googleapis.com/token \
        -d client_id="$GD_CLIENT_ID" \
        -d client_secret="$GD_CLIENT_SECRET" \
        -d refresh_token="$GD_REFRESH_TOKEN" \
        -d grant_type="refresh_token")
    
    local access_token=$(echo "$token_response" | jq -r .access_token 2>/dev/null)
    local expires_in=$(echo "$token_response" | jq -r .expires_in 2>/dev/null)

    if [[ -z "$access_token" || "$access_token" == "null" ]]; then
        local error_msg=$(echo "$token_response" | jq -r .error_description 2>/dev/null)
        print_message "ERROR" "Failed to get Access Token for Google Drive. Maybe Refresh Token expired or invalid. Error: ${error_msg:-Unknown error}."
        print_message "ACTION" "Please reconfigure Google Drive in 'Upload Method' menu."
        return 1
    fi
    echo "$access_token"
    return 0
}

send_google_drive_document() {
    local file_path="$1"
    local file_name=$(basename "$file_path")
    local access_token=$(get_google_access_token)

    if [[ -z "$access_token" ]]; then
        print_message "ERROR" "Failed to send backup to Google Drive: Access Token not retrieved."
        return 1
    fi

    local mime_type="application/gzip"
    local upload_url="https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart"

    local metadata_file=$(mktemp)
    
    local metadata="{\"name\": \"$file_name\", \"mimeType\": \"$mime_type\""
    if [[ -n "$GD_FOLDER_ID" ]]; then
        metadata="${metadata}, \"parents\": [\"$GD_FOLDER_ID\"]"
    fi
    metadata="${metadata}}"
    
    echo "$metadata" > "$metadata_file"

    local response=$(curl -s -X POST "$upload_url" \
        -H "Authorization: Bearer $access_token" \
        -F "metadata=@$metadata_file;type=application/json" \
        -F "file=@$file_path;type=$mime_type")

    rm -f "$metadata_file"

    local file_id=$(echo "$response" | jq -r .id 2>/dev/null)
    local error_message=$(echo "$response" | jq -r .error.message 2>/dev/null)
    local error_code=$(echo "$response" | jq -r .error.code 2>/dev/null)

    if [[ -n "$file_id" && "$file_id" != "null" ]]; then
        return 0
    else
        print_message "ERROR" "Error uploading to Google Drive. Code: ${error_code:-Unknown}. Message: ${error_message:-Unknown error}. Full API response: ${response}"
        return 1
    fi
}

create_backup() {
    print_message "INFO" "Starting backup process..."
    echo ""
    
    REMNAWAVE_VERSION=$(get_remnawave_version)
    TIMESTAMP=$(date +%Y-%m-%d"_"%H_%M_%S)
    BACKUP_FILE_DB="dump_${TIMESTAMP}.sql.gz"
    BACKUP_FILE_FINAL="remnawave_backup_${TIMESTAMP}.tar.gz"
    
    mkdir -p "$BACKUP_DIR" || { 
        echo -e "${RED}❌ Error: Failed to create backup directory. Check permissions.${RESET}"
        send_telegram_message "❌ Error: Failed to create backup directory ${BOLD}$BACKUP_DIR${RESET}." "None"
        exit 1
    }
    
    if ! docker inspect remnawave-db > /dev/null 2>&1 || ! docker container inspect -f '{{.State.Running}}' remnawave-db 2>/dev/null | grep -q "true"; then
        echo -e "${RED}❌ Error: Container ${BOLD}'remnawave-db'${RESET} not found or not running. Cannot backup database.${RESET}"
        local error_msg="❌ Error: Container ${BOLD}'remnawave-db'${RESET} not found or not running. Backup failed."
        if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
            send_telegram_message "$error_msg" "None"
        elif [[ "$UPLOAD_METHOD" == "google_drive" ]]; then
            print_message "ERROR" "Google Drive upload impossible due to DB container error."
        fi
        exit 1
    fi
    
    print_message "INFO" "Creating PostgreSQL dump and compressing..."
    if ! docker exec -t "remnawave-db" pg_dumpall -c -U "$DB_USER" | gzip -9 > "$BACKUP_DIR/$BACKUP_FILE_DB"; then
        STATUS=$?
        echo -e "${RED}❌ Error creating PostgreSQL dump. Exit code: ${BOLD}$STATUS${RESET}. Check DB user and container access.${RESET}"
        local error_msg="❌ Error creating PostgreSQL dump. Exit code: ${BOLD}${STATUS}${RESET}"
        if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
            send_telegram_message "$error_msg" "None"
        elif [[ "$UPLOAD_METHOD" == "google_drive" ]]; then
            print_message "ERROR" "Google Drive upload impossible due to DB dump error."
        fi
        exit $STATUS
    fi
    
    print_message "SUCCESS" "PostgreSQL dump created successfully."
    echo ""
    print_message "INFO" "Archiving Remnawave directory and creating final backup..."
    BACKUP_ITEMS=("$BACKUP_FILE_DB")
    
    REMNAWAVE_DIR_ARCHIVE="remnawave_dir_${TIMESTAMP}.tar.gz"
    
    if [ -d "$REMNALABS_ROOT_DIR" ]; then
        print_message "INFO" "Archiving directory ${BOLD}${REMNALABS_ROOT_DIR}${RESET}..."
        
        local exclude_args=""
        for pattern in $BACKUP_EXCLUDE_PATTERNS; do
            exclude_args+="--exclude=$pattern "
        done
        
        if eval "tar -czf '$BACKUP_DIR/$REMNAWAVE_DIR_ARCHIVE' $exclude_args -C '$(dirname "$REMNALABS_ROOT_DIR")' '$(basename "$REMNALABS_ROOT_DIR")'"; then
            print_message "SUCCESS" "Remnawave directory successfully archived."
            BACKUP_ITEMS+=("$REMNAWAVE_DIR_ARCHIVE")
        else
            STATUS=$?
            echo -e "${RED}❌ Error archiving Remnawave directory. Exit code: ${BOLD}$STATUS${RESET}.${RESET}"
            local error_msg="❌ Error archiving Remnawave directory. Exit code: ${BOLD}${STATUS}${RESET}"
            if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
                send_telegram_message "$error_msg" "None"
            fi
            exit $STATUS
        fi
    else
        print_message "ERROR" "Directory ${BOLD}${REMNALABS_ROOT_DIR}${RESET} not found!"
        exit 1
    fi
    
    echo ""

    create_bot_backup

    # Custom Dirs Backup
    if [[ -f "$CUSTOM_DIRS_FILE" ]]; then
        print_message "INFO" "Backing up additional custom directories..."
        local custom_meta=""
        local cust_count=0
        while IFS= read -r custom_path; do
            [[ -z "$custom_path" ]] && continue
            if [[ -d "$custom_path" ]]; then
                local clean_name=$(basename "$custom_path")
                local cust_archive="custom_dir_${cust_count}_${TIMESTAMP}.tar.gz"
                
                # Using parent directory to tar the folder
                if tar -czf "$BACKUP_DIR/$cust_archive" -C "$(dirname "$custom_path")" "$(basename "$custom_path")"; then
                    print_message "SUCCESS" "Archived custom dir: $custom_path"
                    BACKUP_ITEMS+=("$cust_archive")
                    # Store metadata: archive_name|original_path
                    custom_meta+="${cust_archive}|${custom_path}"$'\n'
                    ((cust_count++))
                else
                    print_message "ERROR" "Failed to archive custom dir: $custom_path"
                fi
            else
                print_message "WARN" "Custom directory not found, skipping: $custom_path"
            fi
        done < "$CUSTOM_DIRS_FILE"
        
        if [[ -n "$custom_meta" ]]; then
            echo "$custom_meta" > "$BACKUP_DIR/custom_dirs_metadata.txt"
            BACKUP_ITEMS+=("custom_dirs_metadata.txt")
        fi
    fi
    
    echo ""

    if ! tar -czf "$BACKUP_DIR/$BACKUP_FILE_FINAL" -C "$BACKUP_DIR" "${BACKUP_ITEMS[@]}"; then
        STATUS=$?
        echo -e "${RED}❌ Error creating final backup archive. Exit code: ${BOLD}$STATUS${RESET}.${RESET}"
        local error_msg="❌ Error creating final backup archive. Exit code: ${BOLD}${STATUS}${RESET}"
        if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
            send_telegram_message "$error_msg" "None"
        fi
        exit $STATUS
    fi
    
    print_message "SUCCESS" "Final backup archive created: ${BOLD}${BACKUP_DIR}/${BACKUP_FILE_FINAL}${RESET}"
    echo ""
    
    print_message "INFO" "Cleaning up intermediate backup files..."
    for item in "${BACKUP_ITEMS[@]}"; do
        rm -f "$BACKUP_DIR/$item"
    done
    print_message "SUCCESS" "Intermediate files removed."
    echo ""
    
    print_message "INFO" "Sending backup (${UPLOAD_METHOD})..."
    local DATE=$(date +'%Y-%m-%d %H:%M:%S')
    local bot_status=""
    if [[ "$BOT_BACKUP_ENABLED" == "true" ]]; then
        bot_status=$'\n🤖 *Telegram Bot:* included'
    fi
    
    if [[ "$cust_count" -gt 0 ]]; then
        bot_status+=$'\n📂 *Custom Dirs:* '"${cust_count}"
    fi

    local caption_text=$'💾 #backup_success\n➖➖➖➖➖➖➖➖➖\n✅ *Backup created successfully*\n🌊 *Remnawave:* '"${REMNAWAVE_VERSION}${bot_status}"$'\n📁 *DB + Directory*\n📅 *Date:* '"${DATE}"
    local backup_size=$(du -h "$BACKUP_DIR/$BACKUP_FILE_FINAL" | awk '{print $1}')

    if [[ -f "$BACKUP_DIR/$BACKUP_FILE_FINAL" ]]; then
        if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
            if send_telegram_document "$BACKUP_DIR/$BACKUP_FILE_FINAL" "$caption_text"; then
                print_message "SUCCESS" "Backup successfully sent to Telegram."
            else
                echo -e "${RED}❌ Error sending backup to Telegram. Check Telegram API settings (token, chat ID).${RESET}"
            fi
        elif [[ "$UPLOAD_METHOD" == "google_drive" ]]; then
            if send_google_drive_document "$BACKUP_DIR/$BACKUP_FILE_FINAL"; then
                print_message "SUCCESS" "Backup successfully sent to Google Drive."
                local tg_success_message=$'💾 #backup_success\n➖➖➖➖➖➖➖➖➖\n✅ *Backup sent to Google Drive*\n🌊 *Remnawave:* '"${REMNAWAVE_VERSION}${bot_status}"$'\n📁 *DB + Directory*\n📏 *Size:* '"${backup_size}"$'\n📅 *Date:* '"${DATE}"
                
                if send_telegram_message "$tg_success_message"; then
                    print_message "SUCCESS" "Notification sent to Telegram."
                else
                    print_message "ERROR" "Failed to send notification to Telegram."
                fi
            else
                echo -e "${RED}❌ Error sending backup to Google Drive. Check Google Drive API settings.${RESET}"
                send_telegram_message "❌ Error: Failed to send backup to Google Drive. See logs." "None"
            fi
        else
            print_message "WARN" "Unknown upload method: ${BOLD}${UPLOAD_METHOD}${RESET}. Backup not sent."
            send_telegram_message "❌ Error: Unknown upload method: ${BOLD}${UPLOAD_METHOD}${RESET}. File: ${BOLD}${BACKUP_FILE_FINAL}${RESET} not sent." "None"
        fi
    else
        echo -e "${RED}❌ Error: Final backup file not found: ${BOLD}${BACKUP_DIR}/${BACKUP_FILE_FINAL}${RESET}. Cannot send.${RESET}"
        local error_msg="❌ Error: Final backup file not found: ${BOLD}${BACKUP_FILE_FINAL}${RESET}"
        if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
            send_telegram_message "$error_msg" "None"
        elif [[ "$UPLOAD_METHOD" == "google_drive" ]]; then
            print_message "ERROR" "Google Drive upload impossible: file not found."
        fi
        exit 1
    fi
    
    echo ""
    
    print_message "INFO" "Applying retention policy (keep last ${BOLD}${RETAIN_BACKUPS_DAYS}${RESET} days)..."
    find "$BACKUP_DIR" -maxdepth 1 -name "remnawave_backup_*.tar.gz" -mtime +$RETAIN_BACKUPS_DAYS -delete
    print_message "SUCCESS" "Retention policy applied. Old backups removed."
    
    echo ""
    
    {
        check_update_status >/dev/null 2>&1
        
        if [[ "$UPDATE_AVAILABLE" == true ]]; then
            local CURRENT_VERSION="$VERSION"
            local REMOTE_VERSION_LATEST
            REMOTE_VERSION_LATEST=$(curl -fsSL "$SCRIPT_REPO_URL" 2>/dev/null | grep -m 1 "^VERSION=" | cut -d'"' -f2)
            
            if [[ -n "$REMOTE_VERSION_LATEST" ]]; then
                local update_msg=$'⚠️ *Script Update Available*\n🔄 *Current Version:* '"${CURRENT_VERSION}"$'\n🆕 *Latest Version:* '"${REMOTE_VERSION_LATEST}"$'\n\n📥 Update via *«Script Update»* in main menu'
                send_telegram_message "$update_msg" >/dev/null 2>&1
            fi
        fi
    } &
}

setup_auto_send() {
    echo ""
    if [[ $EUID -ne 0 ]]; then
        print_message "WARN" "Root privileges required for cron setup. Please run with '${BOLD}sudo'${RESET}.${RESET}"
        read -rp "Press Enter to continue..."
        return
    fi
    while true; do
        clear
        echo -e "${GREEN}${BOLD}Auto-Send Configuration${RESET}"
        echo ""
        if [[ -n "$CRON_TIMES" ]]; then
            print_message "INFO" "Auto-send enabled at: ${BOLD}${CRON_TIMES}${RESET} UTC+0."
        else
            print_message "INFO" "Auto-send is ${BOLD}DISABLED${RESET}."
        fi
        echo ""
        echo "   1. Enable/Overwrite auto-send backup"
        echo "   2. Disable auto-send backup"
        echo "   0. Back to Main Menu"
        echo ""
        read -rp "${GREEN}[?]${RESET} Select option: " choice
        echo ""
        case $choice in
            1)
                local server_offset_str=$(date +%z)
                local offset_sign="${server_offset_str:0:1}"
                local offset_hours=$((10#${server_offset_str:1:2}))
                local offset_minutes=$((10#${server_offset_str:3:2}))

                local server_offset_total_minutes=$((offset_hours * 60 + offset_minutes))
                if [[ "$offset_sign" == "-" ]]; then
                    server_offset_total_minutes=$(( -server_offset_total_minutes ))
                fi

                echo "Select auto-send frequency:"
                echo "  1) Specific time (e.g., 08:00 12:00 18:00)"
                echo "  2) Hourly"
                echo "  3) Daily"
                read -rp "Your choice: " send_choice
                echo ""

                cron_times_to_write=()
                user_friendly_times_local=""
                invalid_format=false

                if [[ "$send_choice" == "1" ]]; then
                    echo "Enter desired send times in UTC+0 (e.g., 08:00 12:00):"
                    read -rp "Times separated by space: " times
                    IFS=' ' read -ra arr <<< "$times"

                    for t in "${arr[@]}"; do
                        if [[ $t =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
                            local hour_utc_input=$((10#${BASH_REMATCH[1]}))
                            local min_utc_input=$((10#${BASH_REMATCH[2]}))

                            if (( hour_utc_input >= 0 && hour_utc_input <= 23 && min_utc_input >= 0 && min_utc_input <= 59 )); then
                                local total_minutes_utc=$((hour_utc_input * 60 + min_utc_input))
                                local total_minutes_local=$((total_minutes_utc + server_offset_total_minutes))

                                while (( total_minutes_local < 0 )); do
                                    total_minutes_local=$((total_minutes_local + 24 * 60))
                                done
                                while (( total_minutes_local >= 24 * 60 )); do
                                    total_minutes_local=$((total_minutes_local - 24 * 60))
                                done

                                local hour_local=$((total_minutes_local / 60))
                                local min_local=$((total_minutes_local % 60))

                                cron_times_to_write+=("$min_local $hour_local")
                                user_friendly_times_local+="$t "
                            else
                                print_message "ERROR" "Invalid time value: ${BOLD}$t${RESET} (hours 0-23, minutes 0-59)."
                                invalid_format=true
                                break
                            fi
                        else
                            print_message "ERROR" "Invalid time format: ${BOLD}$t${RESET} (expected HH:MM)."
                            invalid_format=true
                            break
                        fi
                    done
                elif [[ "$send_choice" == "2" ]]; then
                    cron_times_to_write=("@hourly")
                    user_friendly_times_local="@hourly"
                elif [[ "$send_choice" == "3" ]]; then
                    cron_times_to_write=("@daily")
                    user_friendly_times_local="@daily"
                else
                    print_message "ERROR" "Invalid choice."
                    continue
                fi

                echo ""

                if [ "$invalid_format" = true ] || [ ${#cron_times_to_write[@]} -eq 0 ]; then
                    print_message "ERROR" "Auto-send not configured due to input errors. Please try again."
                    continue
                fi

                print_message "INFO" "Configuring cron task..."

                local temp_crontab_file=$(mktemp)

                if ! crontab -l > "$temp_crontab_file" 2>/dev/null; then
                    touch "$temp_crontab_file"
                fi

                if ! grep -q "^SHELL=" "$temp_crontab_file"; then
                    echo "SHELL=/bin/bash" | cat - "$temp_crontab_file" > "$temp_crontab_file.tmp"
                    mv "$temp_crontab_file.tmp" "$temp_crontab_file"
                    print_message "INFO" "SHELL=/bin/bash added to crontab."
                fi

                if ! grep -q "^PATH=" "$temp_crontab_file"; then
                    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin" | cat - "$temp_crontab_file" > "$temp_crontab_file.tmp"
                    mv "$temp_crontab_file.tmp" "$temp_crontab_file"
                    print_message "INFO" "PATH variable added to crontab."
                else
                    print_message "INFO" "PATH variable already exists in crontab."
                fi

                grep -vF "$SCRIPT_PATH backup" "$temp_crontab_file" > "$temp_crontab_file.tmp"
                mv "$temp_crontab_file.tmp" "$temp_crontab_file"

                for time_entry_local in "${cron_times_to_write[@]}"; do
                    if [[ "$time_entry_local" == "@hourly" ]] || [[ "$time_entry_local" == "@daily" ]]; then
                        echo "$time_entry_local $SCRIPT_PATH backup >> /var/log/rw_backup_cron.log 2>&1" >> "$temp_crontab_file"
                    else
                        echo "$time_entry_local * * * $SCRIPT_PATH backup >> /var/log/rw_backup_cron.log 2>&1" >> "$temp_crontab_file"
                    fi
                done

                if crontab "$temp_crontab_file"; then
                    print_message "SUCCESS" "CRON task successfully installed."
                else
                    print_message "ERROR" "Failed to install CRON task. Check permissions."
                fi

                rm -f "$temp_crontab_file"

                CRON_TIMES="${user_friendly_times_local% }"
                save_config
                print_message "SUCCESS" "Auto-send set to: ${BOLD}${CRON_TIMES}${RESET} UTC+0."
                ;;
            2)
                print_message "INFO" "Disabling auto-send..."
                (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH backup") | crontab -

                CRON_TIMES=""
                save_config
                print_message "SUCCESS" "Auto-send disabled."
                ;;
            0) break ;;
            *) print_message "ERROR" "Invalid input. Please select one of the options." ;;
        esac
        echo ""
        read -rp "Press Enter to continue..."
    done
    echo ""
}
    
restore_backup() {
    clear
    echo "${GREEN}${BOLD}Restore from Backup${RESET}"
    echo ""
    
    print_message "INFO" "Place backup file in: ${BOLD}${BACKUP_DIR}${RESET}"
    echo ""
    
    if ! compgen -G "$BACKUP_DIR/remnawave_backup_*.tar.gz" > /dev/null; then
        print_message "ERROR" "Error: No backup files found in ${BOLD}${BACKUP_DIR}${RESET}. Please place backup file there."
        echo ""
        read -rp "Press Enter to return to menu..."
        return
    fi
    
    readarray -t SORTED_BACKUP_FILES < <(find "$BACKUP_DIR" -maxdepth 1 -name "remnawave_backup_*.tar.gz" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)
    
    if [ ${#SORTED_BACKUP_FILES[@]} -eq 0 ]; then
        print_message "ERROR" "Error: No backup files found in ${BOLD}${BACKUP_DIR}${RESET}."
        read -rp "Press Enter to return to menu..."
        return
    fi
    
    echo ""
    echo "Select file to restore:"
    local i=1
    for file in "${SORTED_BACKUP_FILES[@]}"; do
        echo " $i) ${file##*/}"
        i=$((i+1))
    done
    echo ""
    echo " 0) Back to Main Menu"
    echo ""
    
    local user_choice
    local selected_index
    
    while true; do
        read -rp "${GREEN}[?]${RESET} Enter file number (0 to exit): " user_choice
        
        if [[ "$user_choice" == "0" ]]; then
            print_message "INFO" "Restoration cancelled by user."
            read -rp "Press Enter to return to menu..."
            return
        fi
        
        if ! [[ "$user_choice" =~ ^[0-9]+$ ]]; then
            print_message "ERROR" "Invalid input. Please enter a number."
            continue
        fi
        
        selected_index=$((user_choice - 1))
        
        if (( selected_index >= 0 && selected_index < ${#SORTED_BACKUP_FILES[@]} )); then
            SELECTED_BACKUP="${SORTED_BACKUP_FILES[$selected_index]}"
            break
        else
            print_message "ERROR" "Invalid number. Please select from list."
        fi
    done
    
    echo ""
    
    print_message "WARN" "Restoration will completely overwrite current DB"
    echo "       and Remnawave directory"
    echo ""
    print_message "INFO" "Script configuration DB User: ${BOLD}${GREEN}${DB_USER}${RESET}"
    read -rp "$(echo -e "${GREEN}[?]${RESET} Enter ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET} to continue: ")" db_user_confirm
    
    if [[ ! "$db_user_confirm" =~ ^[Yy]$ ]]; then
        print_message "INFO" "Restoration cancelled."
        read -rp "Press Enter to return to menu..."
        return
    fi

    echo ""
    read -rp "$(echo -e "${GREEN}[?]${RESET} Now enter panel DB name (default: postgres): ")" restore_db_name
    restore_db_name="${restore_db_name:-postgres}"
    
    clear
    
    print_message "INFO" "Starting Remnawave reset and restore process..."
    echo ""
    
    if [[ -d "$REMNALABS_ROOT_DIR" ]]; then
        print_message "INFO" "Directory ${BOLD}${REMNALABS_ROOT_DIR}${RESET} exists. Stopping containers and cleaning..."
        
        if cd "$REMNALABS_ROOT_DIR" 2>/dev/null && [[ -f "docker-compose.yml" ]]; then
            print_message "INFO" "Stopping existing Remnawave containers, please wait..."
            docker compose down 2>/dev/null || print_message "WARN" "Failed to stop containers (maybe already stopped)."
        else
            print_message "INFO" "Docker Compose file not found, skipping container stop."
        fi
        
        cd /
        
        print_message "INFO" "Removing old Remnawave directory..."
        if ! rm -rf "$REMNALABS_ROOT_DIR"; then
            print_message "ERROR" "Failed to remove directory ${BOLD}${REMNALABS_ROOT_DIR}${RESET}."
            read -rp "Press Enter to return to menu..."
            return 1
        fi
        print_message "SUCCESS" "Old directory removed."
    else
        print_message "INFO" "Directory ${BOLD}${REMNALABS_ROOT_DIR}${RESET} does not exist. Fresh install."
    fi
    
    print_message "INFO" "Creating new Remnawave directory..."
    if ! mkdir -p "$REMNALABS_ROOT_DIR"; then
        print_message "ERROR" "Failed to create directory ${BOLD}${REMNALABS_ROOT_DIR}${RESET}."
        read -rp "Press Enter to return to menu..."
        return 1
    fi
    print_message "SUCCESS" "New directory created."
    
    print_message "INFO" "Unpacking backup archive..."
    local temp_restore_dir="$BACKUP_DIR/restore_temp_$$"
    mkdir -p "$temp_restore_dir"
    
    if ! tar -xzf "$SELECTED_BACKUP" -C "$temp_restore_dir"; then
        STATUS=$?
        echo -e "${RED}❌ Error unpacking archive ${BOLD}${SELECTED_BACKUP##*/}${RESET}. Exit code: ${BOLD}$STATUS${RESET}.${RESET}"
        if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
            send_telegram_message "❌ Error unpacking archive: ${BOLD}${SELECTED_BACKUP##*/}${RESET}. Exit code: ${BOLD}${STATUS}${RESET}" "None"
        fi
        [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
        read -rp "Press Enter to return to menu..."
        return 1
    fi
    
    print_message "SUCCESS" "Archive successfully unpacked to temp dir."
    echo ""
    
    print_message "INFO" "Looking for Remnawave directory archive..."
    local REMNAWAVE_DIR_ARCHIVE=$(find "$temp_restore_dir" -name "remnawave_dir_*.tar.gz" | head -n 1)
    
    if [[ -n "$REMNAWAVE_DIR_ARCHIVE" ]]; then
        print_message "INFO" "Found Remnawave directory archive. Restoring..."
        
        local temp_extract_dir="$BACKUP_DIR/extract_temp_$$"
        mkdir -p "$temp_extract_dir"
        
        if tar -xzf "$REMNAWAVE_DIR_ARCHIVE" -C "$temp_extract_dir"; then
            print_message "SUCCESS" "Directory archive unpacked."
            
            local extracted_dir=$(find "$temp_extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)

            if [[ -n "$extracted_dir" && -d "$extracted_dir" ]]; then
                print_message "INFO" "Copying files to Remnawave directory (source folder: $(basename "$extracted_dir"))..."

                if cp -rf "$extracted_dir"/. "$REMNALABS_ROOT_DIR/" 2>/dev/null; then
                    print_message "SUCCESS" "Remnawave files restored."
                else
                    print_message "ERROR" "Error copying Remnawave files."
                    rm -rf "$temp_extract_dir"
                    [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
                    read -rp "Press Enter to return to menu..."
                    return 1
                fi
            else
                print_message "ERROR" "Failed to find directory with Remnawave files in archive."
                rm -rf "$temp_extract_dir"
                [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
                read -rp "Press Enter to return to menu..."
                return 1
            fi
            
            rm -rf "$temp_extract_dir"
        else
            print_message "ERROR" "Error unpacking directory archive."
            rm -rf "$temp_extract_dir"
            [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
            read -rp "Press Enter to return to menu..."
            return 1
        fi
    else
        print_message "WARN" "Remnawave directory archive not found in backup."
        print_message "INFO" "Maybe old backup format with separate .env files"
        
        ENV_NODE_RESTORE_PATH="$REMNALABS_ROOT_DIR/$ENV_NODE_FILE"
        ENV_RESTORE_PATH="$REMNALABS_ROOT_DIR/$ENV_FILE"
        
        if [ -f "$temp_restore_dir/$ENV_NODE_FILE" ]; then
            print_message "INFO" "Found file ${BOLD}${ENV_NODE_FILE}${RESET} (old format). Restoring..."
            mv "$temp_restore_dir/$ENV_NODE_FILE" "$ENV_NODE_RESTORE_PATH" || {
                print_message "ERROR" "Error restoring ${BOLD}${ENV_NODE_FILE}${RESET}."
                [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
                read -rp "Press Enter to return to menu..."
                return 1
            }
            print_message "SUCCESS" "File ${BOLD}${ENV_NODE_FILE}${RESET} restored."
        fi
        
        if [ -f "$temp_restore_dir/$ENV_FILE" ]; then
            print_message "INFO" "Found file ${BOLD}${ENV_FILE}${RESET} (old format). Restoring..."
            mv "$temp_restore_dir/$ENV_FILE" "$ENV_RESTORE_PATH" || {
                print_message "ERROR" "Error restoring ${BOLD}${ENV_FILE}${RESET}."
                [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
                read -rp "Press Enter to return to menu..."
                return 1
            }
            print_message "SUCCESS" "File ${BOLD}${ENV_FILE}${RESET} restored."
        fi
    fi
    
    print_message "INFO" "Checking and removing old Remnawave DB volumes..."
    if docker volume ls -q | grep -q "remnawave-db-data"; then
        if docker volume rm remnawave-db-data 2>/dev/null; then
            print_message "SUCCESS" "Old volume remnawave-db-data removed."
        else
            print_message "WARN" "Failed to remove volume remnawave-db-data (maybe in use)."
        fi
    else
        print_message "INFO" "No old DB volumes found."
    fi
    
    if ! cd "$REMNALABS_ROOT_DIR"; then
        print_message "ERROR" "Failed to change to restored directory ${BOLD}${REMNALABS_ROOT_DIR}${RESET}."
        [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
        read -rp "Press Enter to return to menu..."
        return 1
    fi
    
    if [[ ! -f "docker-compose.yml" ]]; then
        print_message "ERROR" "docker-compose.yml not found in restored directory."
        [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
        read -rp "Press Enter to return to menu..."
        return 1
    fi
    
    echo ""
    print_message "INFO" "Starting Remnawave DB container..."
    docker compose rm -f remnawave-db > /dev/null 2>&1
    
    if ! docker compose up -d remnawave-db; then
        print_message "ERROR" "Failed to start Remnawave DB container."
        [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
        read -rp "Press Enter to return to menu..."
        return 1
    fi

    echo ""
    print_message "INFO" "Waiting for database readiness..."
    local wait_count=0
    local max_wait=60
    
    until [ "$(docker inspect --format='{{.State.Health.Status}}' remnawave-db)" == "healthy" ]; do
        sleep 2
        echo -n "."
        wait_count=$((wait_count + 1))
        if [ $wait_count -gt $max_wait ]; then
            echo ""
            print_message "ERROR" "Remnawave DB readiness timeout exceeded."
            [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
            read -rp "Press Enter to return to menu..."
            return 1
        fi
    done
    echo ""
    print_message "SUCCESS" "Database is ready."
    
    echo ""
    
    print_message "INFO" "Restoring database from dump..."
    local DUMP_FILE_GZ=$(find "$temp_restore_dir" -name "dump_*.sql.gz" | head -n 1)
    
    if [[ -z "$DUMP_FILE_GZ" ]]; then
        print_message "ERROR" "Dump file not found in archive. Cannot restore."
        [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
        read -rp "Press Enter to return to menu..."
        return 1
    fi
    
    local DUMP_FILE="${DUMP_FILE_GZ%.gz}"
    
    if ! gunzip "$DUMP_FILE_GZ"; then
        print_message "ERROR" "Failed to decompress SQL dump: ${DUMP_FILE_GZ}"
        [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
        read -rp "Press Enter to return to menu..."
        return 1
    fi
    
    if ! docker exec -i remnawave-db psql -q -U "${DB_USER}" -d "$restore_db_name" > /dev/null 2> "$temp_restore_dir/restore_errors.log" < "$DUMP_FILE"; then
        print_message "ERROR" "Error restoring database dump."
        echo ""
        print_message "WARN" "${YELLOW}Restore error log:${RESET}"
        cat "$temp_restore_dir/restore_errors.log"
        [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
        read -rp "Press Enter to return to menu..."
        return 1
    fi
    
    print_message "SUCCESS" "Database successfully restored."
    echo ""
    print_message "INFO" "Starting all Remnawave containers..."
    if ! docker compose up -d; then
        print_message "ERROR" "Failed to start all Remnawave containers."
        read -rp "Press Enter to return to menu..."
        return 1
    fi
    
    echo ""
    restore_bot_backup "$temp_restore_dir"
    
    # Custom Dirs Restore Logic
    if [[ -f "$temp_restore_dir/custom_dirs_metadata.txt" ]]; then
        echo ""
        print_message "INFO" "Found custom directories backup metadata."
        
        while IFS='|' read -r archive_name original_path; do
             [[ -z "$archive_name" || -z "$original_path" ]] && continue
             
             echo ""
             print_message "ACTION" "Restore custom directory: ${BOLD}${original_path}${RESET}?"
             read -rp " (Y/N): " confirm_cust
             if [[ "$confirm_cust" =~ ^[yY]$ ]]; then
                  local archive_path="$temp_restore_dir/$archive_name"
                  if [[ -f "$archive_path" ]]; then
                      print_message "INFO" "Restoring $original_path..."
                      mkdir -p "$(dirname "$original_path")"
                      
                      # Be careful with existing files
                      if tar -xzf "$archive_path" -C "$(dirname "$original_path")"; then
                          print_message "SUCCESS" "Restored $original_path"
                      else
                          print_message "ERROR" "Failed to restore $original_path"
                      fi
                  else
                      print_message "ERROR" "Archive file $archive_name not found."
                  fi
             else
                  print_message "INFO" "Skipping $original_path"
             fi
        done < "$temp_restore_dir/custom_dirs_metadata.txt"
    fi

    print_message "INFO" "Removing temporary restore files..."
    [[ -n "$temp_restore_dir" && -d "$temp_restore_dir" ]] && rm -rf "$temp_restore_dir"
    
    sleep 3
    
    echo ""
    print_message "SUCCESS" "Restoration complete. All containers started."
    
    REMNAWAVE_VERSION=$(get_remnawave_version)
    local restore_msg=$'💾 #restore_success\n➖➖➖➖➖➖➖➖➖\n✅ *Restoration successfully completed*\n🌊 *Remnawave:* '"${REMNAWAVE_VERSION}"
    send_telegram_message "$restore_msg" >/dev/null 2>&1
    
    read -rp "Press Enter to continue..."
    return
}

update_script() {
    print_message "INFO" "Checking for updates..."
    echo ""
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}⛔ Root privileges are required to update the script. Please run with '${BOLD}sudo'${RESET}.${RESET}"
        read -rp "Press Enter to continue..."
        return
    fi

    print_message "INFO" "Getting latest version info from GitHub..."
    local TEMP_REMOTE_VERSION_FILE
    TEMP_REMOTE_VERSION_FILE=$(mktemp)

    if ! curl -fsSL "$SCRIPT_REPO_URL" 2>/dev/null | head -n 100 > "$TEMP_REMOTE_VERSION_FILE"; then
        print_message "ERROR" "Failed to download version info from GitHub. Check URL or network."
        rm -f "$TEMP_REMOTE_VERSION_FILE"
        read -rp "Press Enter to continue..."
        return
    fi

    REMOTE_VERSION=$(grep -m 1 "^VERSION=" "$TEMP_REMOTE_VERSION_FILE" | cut -d'"' -f2)
    rm -f "$TEMP_REMOTE_VERSION_FILE"

    if [[ -z "$REMOTE_VERSION" ]]; then
        print_message "ERROR" "Failed to extract version from remote script. VERSION format might have changed."
        read -rp "Press Enter to continue..."
        return
    fi

    print_message "INFO" "Current Version: ${BOLD}${YELLOW}${VERSION}${RESET}"
    print_message "INFO" "Available Version: ${BOLD}${GREEN}${REMOTE_VERSION}${RESET}"
    echo ""

    compare_versions() {
        local v1="$1"
        local v2="$2"

        local v1_num="${v1//[^0-9.]/}"
        local v2_num="${v2//[^0-9.]/}"

        local v1_sfx="${v1//$v1_num/}"
        local v2_sfx="${v2//$v2_num/}"

        if [[ "$v1_num" == "$v2_num" ]]; then
            if [[ -z "$v1_sfx" && -n "$v2_sfx" ]]; then
                return 0
            elif [[ -n "$v1_sfx" && -z "$v2_sfx" ]]; then
                return 1
            elif [[ "$v1_sfx" < "$v2_sfx" ]]; then
                return 0
            else
                return 1
            fi
        else
            if printf '%s\n' "$v1_num" "$v2_num" | sort -V | head -n1 | grep -qx "$v1_num"; then
                return 0
            else
                return 1
            fi
        fi
    }

    if compare_versions "$VERSION" "$REMOTE_VERSION"; then
        print_message "ACTION" "Update available to version ${BOLD}${REMOTE_VERSION}${RESET}."
        echo -e -n "Update script? Enter ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: "
        read -r confirm_update
        echo ""

        if [[ "${confirm_update,,}" != "y" ]]; then
            print_message "WARN" "Update cancelled by user."
            read -rp "Press Enter to continue..."
            return
        fi
    else
        print_message "INFO" "You have the latest version."
        read -rp "Press Enter to continue..."
        return
    fi

    local TEMP_SCRIPT_PATH="${INSTALL_DIR}/backup-restore.sh.tmp"
    print_message "INFO" "Downloading update..."
    if ! curl -fsSL "$SCRIPT_REPO_URL" -o "$TEMP_SCRIPT_PATH"; then
        print_message "ERROR" "Failed to download new script version."
        read -rp "Press Enter to continue..."
        return
    fi

    if [[ ! -s "$TEMP_SCRIPT_PATH" ]] || ! head -n 1 "$TEMP_SCRIPT_PATH" | grep -q -e '^#!.*bash'; then
        print_message "ERROR" "Downloaded file is empty or not a bash script. Update failed."
        rm -f "$TEMP_SCRIPT_PATH"
        read -rp "Press Enter to continue..."
        return
    fi

    print_message "INFO" "Removing old script backups..."
    find "$(dirname "$SCRIPT_PATH")" -maxdepth 1 -name "${SCRIPT_NAME}.bak.*" -type f -delete
    echo ""

    local BACKUP_PATH_SCRIPT="${SCRIPT_PATH}.bak.$(date +%s)"
    print_message "INFO" "Backing up current script..."
    cp "$SCRIPT_PATH" "$BACKUP_PATH_SCRIPT" || {
        echo -e "${RED}❌ Failed to backup ${BOLD}${SCRIPT_PATH}${RESET}. Update cancelled.${RESET}"
        rm -f "$TEMP_SCRIPT_PATH"
        read -rp "Press Enter to continue..."
        return
    }
    echo ""

    mv "$TEMP_SCRIPT_PATH" "$SCRIPT_PATH" || {
        echo -e "${RED}❌ Error moving temp file to ${BOLD}${SCRIPT_PATH}${RESET}. Check permissions.${RESET}"
        echo -e "${YELLOW}⚠️ Restoring from backup ${BOLD}${BACKUP_PATH_SCRIPT}${RESET}...${RESET}"
        mv "$BACKUP_PATH_SCRIPT" "$SCRIPT_PATH"
        rm -f "$TEMP_SCRIPT_PATH"
        read -rp "Press Enter to continue..."
        return
    }

    chmod +x "$SCRIPT_PATH"
    print_message "SUCCESS" "Script updated to version ${BOLD}${GREEN}${REMOTE_VERSION}${RESET}."
    echo ""
    print_message "INFO" "Restarting script to apply changes..."
    read -rp "Press Enter to restart."
    exec "$SCRIPT_PATH" "$@"
    exit 0
}

remove_script() {
    print_message "WARN" "${YELLOW}WARNING!${RESET} The following will be deleted: "
    echo  " - Script"
    echo  " - Installation directory and all backups"
    echo  " - Symlink (if exists)"
    echo  " - Cron tasks"
    echo ""
    echo -e -n "Are you sure you want to continue? Enter ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: "
    read -r confirm
    echo ""
    
    if [[ "${confirm,,}" != "y" ]]; then
    print_message "WARN" "Removal cancelled."
    read -rp "Press Enter to continue..."
    return
    fi

    if [[ "$EUID" -ne 0 ]]; then
        print_message "WARN" "Root privileges required for full removal. Please run with ${BOLD}sudo${RESET}."
        read -rp "Press Enter to continue..."
        return
    fi

    print_message "INFO" "Removing cron tasks..."
    if crontab -l 2>/dev/null | grep -qF "$SCRIPT_PATH backup"; then
        (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH backup") | crontab -
        print_message "SUCCESS" "Cron tasks for auto-backup removed."
    else
        print_message "INFO" "No cron tasks found."
    fi
    echo ""

    print_message "INFO" "Removing symlink..."
    if [[ -L "$SYMLINK_PATH" ]]; then
        rm -f "$SYMLINK_PATH" && print_message "SUCCESS" "Symlink ${BOLD}${SYMLINK_PATH}${RESET} removed." || print_message "WARN" "Failed to remove symlink ${BOLD}${SYMLINK_PATH}${RESET}. Manual removal might be required."
    elif [[ -e "$SYMLINK_PATH" ]]; then
        print_message "WARN" "${BOLD}${SYMLINK_PATH}${RESET} exists but is not a symlink. Manual check recommended."
    else
        print_message "INFO" "Symlink ${BOLD}${SYMLINK_PATH}${RESET} not found."
    fi
    echo ""

    print_message "INFO" "Removing installation directory and data..."
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR" && print_message "SUCCESS" "Install dir ${BOLD}${INSTALL_DIR}${RESET} (including script, config, backups) removed." || echo -e "${RED}❌ Error removing dir ${BOLD}${INSTALL_DIR}${RESET}. Root rights or process lock might be the issue.${RESET}"
    else
        print_message "INFO" "Install dir ${BOLD}${INSTALL_DIR}${RESET} not found."
    fi
    exit 0
}

configure_upload_method() {
    while true; do
        clear
        echo -e "${GREEN}${BOLD}Configure Backup Upload Method${RESET}"
        echo ""
        print_message "INFO" "Current method: ${BOLD}${UPLOAD_METHOD^^}${RESET}"
        echo ""
        echo "   1. Set method: Telegram"
        echo "   2. Set method: Google Drive"
        echo ""
        echo "   0. Back to Main Menu"
        echo ""
        read -rp "${GREEN}[?]${RESET} Select option: " choice
        echo ""

        case $choice in
            1)
                UPLOAD_METHOD="telegram"
                save_config
                print_message "SUCCESS" "Upload method set to ${BOLD}Telegram${RESET}."
                if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
                    print_message "ACTION" "Please enter Telegram data:"
                    echo ""
                    print_message "INFO" "Create Telegram bot via ${CYAN}@BotFather${RESET} and get API Token"
                    read -rp "   Enter API Token: " BOT_TOKEN
                    echo ""
                    print_message "INFO" "You can find your ID via ${CYAN}@userinfobot${RESET}"
                    read -rp "   Enter your Telegram ID: " CHAT_ID
                    save_config
                    print_message "SUCCESS" "Telegram settings saved."
                fi
                ;;
            2)
                UPLOAD_METHOD="google_drive"
                print_message "SUCCESS" "Upload method set to ${BOLD}Google Drive${RESET}."
                
                local gd_setup_successful=true

                if [[ -z "$GD_CLIENT_ID" || -z "$GD_CLIENT_SECRET" || -z "$GD_REFRESH_TOKEN" ]]; then
                    print_message "ACTION" "Please enter Google Drive API data."
                    echo ""
                    echo "If you don't have Client ID and Client Secret tokens"
                    local guide_url="https://telegra.ph/Nastrojka-Google-API-06-02"
                    print_message "LINK" "Read this guide: ${CYAN}${guide_url}${RESET}"
                    read -rp "   Enter Google Client ID: " GD_CLIENT_ID
                    read -rp "   Enter Google Client Secret: " GD_CLIENT_SECRET
                    
                    clear
                    
                    print_message "WARN" "Browser authorization is required for Refresh Token."
                    print_message "INFO" "Open following link, authorize and copy ${BOLD}code${RESET}:"
                    echo ""
                    local auth_url="https://accounts.google.com/o/oauth2/auth?client_id=${GD_CLIENT_ID}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=https://www.googleapis.com/auth/drive&response_type=code&access_type=offline"
                    print_message "INFO" "${CYAN}${auth_url}${RESET}"
                    echo ""
                    read -rp "Enter code from browser: " AUTH_CODE
                    
                    print_message "INFO" "Getting Refresh Token..."
                    local token_response=$(curl -s -X POST https://oauth2.googleapis.com/token \
                        -d client_id="$GD_CLIENT_ID" \
                        -d client_secret="$GD_CLIENT_SECRET" \
                        -d code="$AUTH_CODE" \
                        -d redirect_uri="urn:ietf:wg:oauth:2.0:oob" \
                        -d grant_type="authorization_code")
                    
                    GD_REFRESH_TOKEN=$(echo "$token_response" | jq -r .refresh_token 2>/dev/null)
                    
                    if [[ -z "$GD_REFRESH_TOKEN" || "$GD_REFRESH_TOKEN" == "null" ]]; then
                        print_message "ERROR" "Failed to get Refresh Token. Check input data."
                        print_message "WARN" "Setup incomplete, method changed to ${BOLD}Telegram${RESET}."
                        UPLOAD_METHOD="telegram"
                        gd_setup_successful=false
                    else
                        print_message "SUCCESS" "Refresh Token successfully received."
                    fi
                    echo
                    
                    if $gd_setup_successful; then
                        echo "   📁 To specify Google Drive folder:"
                        echo "   1. Create and open folder in browser."
                        echo "   2. Look at URL:"
                        echo "      https://drive.google.com/drive/folders/1a2B3cD4eFmNOPqRstuVwxYz"
                        echo "   3. Copy part after /folders/ — that is Folder ID."
                        echo "   4. Leave empty for root folder."
                        echo

                        read -rp "   Enter Google Drive Folder ID: " GD_FOLDER_ID
                    fi
                fi

                save_config

                if $gd_setup_successful; then
                    print_message "SUCCESS" "Google Drive settings saved."
                else
                    print_message "SUCCESS" "Method set to ${BOLD}Telegram${RESET}."
                fi
                ;;
            0) break ;;
            *) print_message "ERROR" "Invalid input." ;;
        esac
        echo ""
        read -rp "Press Enter to continue..."
    done
    echo ""
}

configure_settings() {
    while true; do
        clear
        echo -e "${GREEN}${BOLD}Script Configuration${RESET}"
        echo ""
        echo "   1. Telegram Settings"
        echo "   2. Google Drive Settings"
        echo "   3. Remnawave DB User"
        echo "   4. Remnawave Path"
        echo ""
        echo "   0. Back to Main Menu"
        echo ""
        read -rp "${GREEN}[?]${RESET} Select option: " choice
        echo ""

        case $choice in
            1)
                while true; do
                    clear
                    echo -e "${GREEN}${BOLD}Telegram Settings${RESET}"
                    echo ""
                    print_message "INFO" "Current API Token: ${BOLD}${BOT_TOKEN}${RESET}"
                    print_message "INFO" "Current ID: ${BOLD}${CHAT_ID}${RESET}"
                    print_message "INFO" "Current Message Thread ID: ${BOLD}${TG_MESSAGE_THREAD_ID:-Not set}${RESET}"
                    echo ""
                    echo "   1. Change API Token"
                    echo "   2. Change ID"
                    echo "   3. Change Message Thread ID"
                    echo ""
                    echo "   0. Back"
                    echo ""
                    read -rp "${GREEN}[?]${RESET} Select option: " telegram_choice
                    echo ""

                    case $telegram_choice in
                        1)
                            print_message "INFO" "Create Telegram bot via ${CYAN}@BotFather${RESET} and get API Token"
                            read -rp "   Enter new API Token: " NEW_BOT_TOKEN
                            BOT_TOKEN="$NEW_BOT_TOKEN"
                            save_config
                            print_message "SUCCESS" "API Token updated."
                            ;;
                        2)
                            print_message "INFO" "Enter Chat ID or your Telegram ID"
                            read -rp "   Enter new ID: " NEW_CHAT_ID
                            CHAT_ID="$NEW_CHAT_ID"
                            save_config
                            print_message "SUCCESS" "ID updated."
                            ;;
                        3)
                            print_message "INFO" "Enter Message Thread ID (optional)"
                            read -rp "   Enter Message Thread ID: " NEW_TG_MESSAGE_THREAD_ID
                            TG_MESSAGE_THREAD_ID="$NEW_TG_MESSAGE_THREAD_ID"
                            save_config
                            print_message "SUCCESS" "Message Thread ID updated."
                            ;;
                        0) break ;;
                        *) print_message "ERROR" "Invalid input." ;;
                    esac
                    echo ""
                    read -rp "Press Enter to continue..."
                done
                ;;

            2)
                while true; do
                    clear
                    echo -e "${GREEN}${BOLD}Google Drive Settings${RESET}"
                    echo ""
                    print_message "INFO" "Current Client ID: ${BOLD}${GD_CLIENT_ID:0:8}...${RESET}"
                    print_message "INFO" "Current Client Secret: ${BOLD}${GD_CLIENT_SECRET:0:8}...${RESET}"
                    print_message "INFO" "Current Refresh Token: ${BOLD}${GD_REFRESH_TOKEN:0:8}...${RESET}"
                    print_message "INFO" "Current Folder ID: ${BOLD}${GD_FOLDER_ID:-Root}${RESET}"
                    echo ""
                    echo "   1. Change Google Client ID"
                    echo "   2. Change Google Client Secret"
                    echo "   3. Change Google Refresh Token (requires re-auth)"
                    echo "   4. Change Google Drive Folder ID"
                    echo ""
                    echo "   0. Back"
                    echo ""
                    read -rp "${GREEN}[?]${RESET} Select option: " gd_choice
                    echo ""

                    case $gd_choice in
                        1)
                            echo "If you don't have Client ID and Client Secret tokens"
                            local guide_url="https://telegra.ph/Nastrojka-Google-API-06-02"
                            print_message "LINK" "Read this guide: ${CYAN}${guide_url}${RESET}"
                            read -rp "   Enter new Google Client ID: " NEW_GD_CLIENT_ID
                            GD_CLIENT_ID="$NEW_GD_CLIENT_ID"
                            save_config
                            print_message "SUCCESS" "Google Client ID updated."
                            ;;
                        2)
                            echo "If you don't have Client ID and Client Secret tokens"
                            local guide_url="https://telegra.ph/Nastrojka-Google-API-06-02"
                            print_message "LINK" "Read this guide: ${CYAN}${guide_url}${RESET}"
                            read -rp "   Enter new Google Client Secret: " NEW_GD_CLIENT_SECRET
                            GD_CLIENT_SECRET="$NEW_GD_CLIENT_SECRET"
                            save_config
                            print_message "SUCCESS" "Google Client Secret updated."
                            ;;
                        3)
                            clear
                            print_message "WARN" "Re-authorization in browser required."
                            print_message "INFO" "Open link, authorize and copy ${BOLD}code${RESET}:"
                            echo ""
                            local auth_url="https://accounts.google.com/o/oauth2/auth?client_id=${GD_CLIENT_ID}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=https://www.googleapis.com/auth/drive&response_type=code&access_type=offline"
                            print_message "LINK" "${CYAN}${auth_url}${RESET}"
                            echo ""
                            read -rp "Enter code from browser: " AUTH_CODE
                            
                            print_message "INFO" "Getting Refresh Token..."
                            local token_response=$(curl -s -X POST https://oauth2.googleapis.com/token \
                                -d client_id="$GD_CLIENT_ID" \
                                -d client_secret="$GD_CLIENT_SECRET" \
                                -d code="$AUTH_CODE" \
                                -d redirect_uri="urn:ietf:wg:oauth:2.0:oob" \
                                -d grant_type="authorization_code")
                            
                            NEW_GD_REFRESH_TOKEN=$(echo "$token_response" | jq -r .refresh_token 2>/dev/null)
                            
                            if [[ -z "$NEW_GD_REFRESH_TOKEN" || "$NEW_GD_REFRESH_TOKEN" == "null" ]]; then
                                print_message "ERROR" "Failed to get Refresh Token. Check data."
                                print_message "WARN" "Setup incomplete."
                            else
                                GD_REFRESH_TOKEN="$NEW_GD_REFRESH_TOKEN"
                                save_config
                                print_message "SUCCESS" "Refresh Token updated."
                            fi
                            ;;
                        4)
                            echo
                            read -rp "   Enter new Google Drive Folder ID (leave empty for root): " NEW_GD_FOLDER_ID
                            GD_FOLDER_ID="$NEW_GD_FOLDER_ID"
                            save_config
                            print_message "SUCCESS" "Google Drive Folder ID updated."
                            ;;
                        0) break ;;
                        *) print_message "ERROR" "Invalid input." ;;
                    esac
                    echo ""
                    read -rp "Press Enter to continue..."
                done
                ;;
            3)
                clear
                echo -e "${GREEN}${BOLD}PostgreSQL Username${RESET}"
                echo ""
                print_message "INFO" "Current DB User: ${BOLD}${DB_USER}${RESET}"
                echo ""
                read -rp "   Enter new DB User (default: postgres): " NEW_DB_USER
                DB_USER="${NEW_DB_USER:-postgres}"
                save_config
                print_message "SUCCESS" "DB User updated to ${BOLD}${DB_USER}${RESET}."
                echo ""
                read -rp "Press Enter to continue..."
                ;;
            4)
                clear
                echo -e "${GREEN}${BOLD}Remnawave Path${RESET}"
                echo ""
                print_message "INFO" "Current Path: ${BOLD}${REMNALABS_ROOT_DIR}${RESET}"
                echo ""
                print_message "ACTION" "Select new path:"
                echo " 1. /opt/remnawave"
                echo " 2. /root/remnawave"
                echo " 3. /opt/stacks/remnawave"
                echo " 4. Custom path"
                echo ""
                echo " 0. Back"
                echo ""

                local new_remnawave_path_choice
                while true; do
                    read -rp " ${GREEN}[?]${RESET} Select option: " new_remnawave_path_choice
                    case "$new_remnawave_path_choice" in
                    1) REMNALABS_ROOT_DIR="/opt/remnawave"; break ;;
                    2) REMNALABS_ROOT_DIR="/root/remnawave"; break ;;
                    3) REMNALABS_ROOT_DIR="/opt/stacks/remnawave"; break ;;
                    4) 
                        echo ""
                        print_message "INFO" "Enter full path:"
                        read -rp " Path: " new_custom_remnawave_path
        
                        if [[ -z "$new_custom_remnawave_path" ]]; then
                            print_message "ERROR" "Path cannot be empty."
                            echo ""
                            read -rp "Press Enter to continue..."
                            continue
                        fi
        
                        if [[ ! "$new_custom_remnawave_path" = /* ]]; then
                            print_message "ERROR" "Path must be absolute (start with /)."
                            echo ""
                            read -rp "Press Enter to continue..."
                            continue
                        fi
        
                        new_custom_remnawave_path="${new_custom_remnawave_path%/}"
        
                        if [[ ! -d "$new_custom_remnawave_path" ]]; then
                            print_message "WARN" "Directory ${BOLD}${new_custom_remnawave_path}${RESET} does not exist."
                            read -rp "$(echo -e "${GREEN}[?]${RESET} Continue with this path? ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: ")" confirm_new_custom_path
                            if [[ "$confirm_new_custom_path" != "y" ]]; then
                                echo ""
                                read -rp "Press Enter to continue..."
                                continue
                            fi
                        fi
        
                        REMNALABS_ROOT_DIR="$new_custom_remnawave_path"
                        print_message "SUCCESS" "New path set: ${BOLD}${REMNALABS_ROOT_DIR}${RESET}"
                        break 
                        ;;
                    0) 
                        return
                        ;;
                    *) print_message "ERROR" "Invalid input." ;;
                    esac
                done
                save_config
                print_message "SUCCESS" "Remnawave path updated to ${BOLD}${REMNALABS_ROOT_DIR}${RESET}."
                echo ""
                read -rp "Press Enter to continue..."
                ;;
            0) break ;;
            *) print_message "ERROR" "Invalid input." ;;
        esac
        echo ""
    done
}

check_update_status() {
    local TEMP_REMOTE_VERSION_FILE
    TEMP_REMOTE_VERSION_FILE=$(mktemp)

    if ! curl -fsSL "$SCRIPT_REPO_URL" 2>/dev/null | head -n 100 > "$TEMP_REMOTE_VERSION_FILE"; then
        UPDATE_AVAILABLE=false
        rm -f "$TEMP_REMOTE_VERSION_FILE"
        return
    fi

    local REMOTE_VERSION
    REMOTE_VERSION=$(grep -m 1 "^VERSION=" "$TEMP_REMOTE_VERSION_FILE" | cut -d'"' -f2)
    rm -f "$TEMP_REMOTE_VERSION_FILE"

    if [[ -z "$REMOTE_VERSION" ]]; then
        UPDATE_AVAILABLE=false
        return
    fi

    compare_versions_for_check() {
        local v1="$1"
        local v2="$2"

        local v1_num="${v1//[^0-9.]/}"
        local v2_num="${v2//[^0-9.]/}"

        local v1_sfx="${v1//$v1_num/}"
        local v2_sfx="${v2//$v2_num/}"

        if [[ "$v1_num" == "$v2_num" ]]; then
            if [[ -z "$v1_sfx" && -n "$v2_sfx" ]]; then
                return 0
            elif [[ -n "$v1_sfx" && -z "$v2_sfx" ]]; then
                return 1
            elif [[ "$v1_sfx" < "$v2_sfx" ]]; then
                return 0
            else
                return 1
            fi
        else
            if printf '%s\n' "$v1_num" "$v2_num" | sort -V | head -n1 | grep -qx "$v1_num"; then
                return 0
            else
                return 1
            fi
        fi
    }

    if compare_versions_for_check "$VERSION" "$REMOTE_VERSION"; then
        UPDATE_AVAILABLE=true
    else
        UPDATE_AVAILABLE=false
    fi
}

main_menu() {
    while true; do
        check_update_status
        clear
        echo -e "${GREEN}${BOLD}REMNAWAVE BACKUP & RESTORE by distillium${RESET} "
        if [[ "$UPDATE_AVAILABLE" == true ]]; then
            echo -e "${BOLD}${LIGHT_GRAY}Version: ${VERSION} ${RED}update available${RESET}"
        else
            echo -e "${BOLD}${LIGHT_GRAY}Version: ${VERSION}${RESET}"
        fi
        echo ""
        echo "   1. Create Backup Manually"
        echo "   2. Restore from Backup"
        echo ""
        echo "   3. Configure Bot Backup"
        echo "   4. Configure Auto-Send"
        echo "   5. Configure Upload Method"
        echo "   6. Script Configuration"
        echo "   7. Manage Additional Directories (NEW)"
        echo ""
        echo "   8. Update Script"
        echo "   9. Remove Script"
        echo ""
        echo "   0. Exit"
        echo -e "   —  Quick run: ${BOLD}${GREEN}rw-backup${RESET} available globally"
        echo ""

        read -rp "${GREEN}[?]${RESET} Select option: " choice
        echo ""
        case $choice in
            1) create_backup ; read -rp "Press Enter to continue..." ;;
            2) restore_backup ;;
            3) configure_bot_backup ;;
            4) setup_auto_send ;;
            5) configure_upload_method ;;
            6) configure_settings ;;
            7) manage_custom_dirs ;;
            8) update_script ;;
            9) remove_script ;;
            0) echo "Exiting..."; exit 0 ;;
            *) print_message "ERROR" "Invalid input. Please select one of the options." ; read -rp "Press Enter to continue..." ;;
        esac
    done
}

if ! command -v jq &> /dev/null; then
    print_message "INFO" "Installing 'jq' package for JSON parsing..."
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Error: Root privileges required to install 'jq'. Please install 'jq' manually (e.g., 'sudo apt-get install jq') or run script with sudo.${RESET}"
        exit 1
    fi
    if command -v apt-get &> /dev/null; then
        apt-get update -qq > /dev/null 2>&1
        apt-get install -y jq > /dev/null 2>&1 || { echo -e "${RED}❌ Error: Failed to install 'jq'.${RESET}"; exit 1; }
        print_message "SUCCESS" "'jq' successfully installed."
    else
        print_message "ERROR" "Package manager apt-get not found. Install 'jq' manually."
        exit 1
    fi
fi

if [[ -z "$1" ]]; then
    load_or_create_config
    setup_symlink
    main_menu
elif [[ "$1" == "backup" ]]; then
    load_or_create_config
    create_backup
elif [[ "$1" == "restore" ]]; then
    load_or_create_config
    restore_backup
elif [[ "$1" == "update" ]]; then
    update_script
elif [[ "$1" == "remove" ]]; then
    remove_script
else
    echo -e "${RED}❌ Invalid usage. Available commands: ${BOLD}${0} [backup|restore|update|remove]${RESET}${RESET}"
    exit 1
fi
