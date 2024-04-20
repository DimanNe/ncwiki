function RunVerbosely
   echo -e (set_color brblack)(string escape -- $argv)(set_color normal) 1>&2
   $argv
end



# Reset
set Color_Off   '\033[0m'
# Regular Colors
set Gray        '\033[0;90m'
set BrightGray  '\033[38;5;248m'
set Black       '\033[0;30m'
set Red         '\033[0;31m'
set Green       '\033[0;32m'
set Yellow      '\033[0;33m'
set Blue        '\033[0;34m'
set Purple      '\033[0;35m'
set Cyan        '\033[0;36m'
set White       '\033[0;37m'
# Bold
set BBlack      '\033[1;30m'
set BBrightGray '\033[1;38;5;248m'
set BGray       '\033[1;30m'
set BRed        '\033[1;31m'
set BGreen      '\033[1;32m'
set BYellow     '\033[1;33m'
set BBlue       '\033[1;34m'
set BPurple     '\033[1;35m'
set BCyan       '\033[1;36m'
set BWhite      '\033[1;37m'
# Underline
set UBlack      '\033[4;30m'
set URed        '\033[4;31m'
set UGreen      '\033[4;32m'
set UYellow     '\033[4;33m'
set UBlue       '\033[4;34m'
set UPurple     '\033[4;35m'
set UCyan       '\033[4;36m'
set UWhite      '\033[4;37m'
