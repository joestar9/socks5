#!/bin/bash

set -e

VERSION="2.2.1"
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
       
