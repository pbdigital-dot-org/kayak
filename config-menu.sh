#!/bin/ksh
#
# {{{ CDDL HEADER
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source. A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
# }}}

#
# Copyright 2018 OmniOS Community Edition (OmniOSce) Association.
#

ALTROOT=/mnt
INITIALBOOT=$ALTROOT/.initialboot
IPCALC=/kayak/ipcalc
PASSUTIL=/kayak/passutil

debug=0
if [ "$1" = '-t' ]; then
	debug=1
	shift
else
	trap "" TSTP INT TERM ABRT QUIT
fi

[ "$1" = "-dialog" ] && . /kayak/dialog.sh

dmsg()
{
	[ $debug -eq 1 ] && echo "$@"
}

pause()
{
	echo
	echo "$@"
	echo
	echo "Press return to continue...\\c"
	read a
}

ask()
{
	typeset a=

	while [[ "$a" != [yYnN] ]]; do
		echo "$* (y/n) \\c"
		read a
	done
	[[ "$a" = [yY] ]]
}

show_dialog_menu()
{
	nameref menu="$1"
	typeset title="${2:-configuration}"
	defaultchoice="$3"

	typeset -a args=()
	for i in "${!menu[@]}"; do
		nameref item=menu[$i]
		if [ -n "${item.current}" ]; then
			str=$(printf "%-40s [%s]" \
			    "${item.menu_str}" "`${item.current}`")
		else
			str="${item.menu_str}"
		fi
		args+=($((i + 1)) "$str")
		[ -z "$defaultchoice" -a -n "${item.default}" ] \
		    && defaultchoice=$((i + 1))
	done
	# Return to previous menu should be the default choice.
	[ -z "$defaultchoice" ] && defaultchoice=$((i + 1))

	tmpf=`mktemp`
	dialog \
		--title "OmniOSce $title menu" \
		--hline "Use arrow or hot keys to select one of the options above" \
		--no-ok \
		--no-tags \
		--no-lines \
		--nocancel \
		--default-item "$defaultchoice" \
		--menu "\n " \
		0 0 0 \
		"${args[@]}" 2> $tmpf
	stat=$?
	if [ $stat -eq 0 ]; then
		input="`cat $tmpf`"
	elif [ $debug -eq 1 -a $stat -gt 4 ]; then
		exit 0
	else
		return
	fi
	rm -f $tmpf
	return 0
}

show_text_menu()
{
	nameref menu="$1"
	typeset title="${2:-configuration}"
	typeset -i input

	# Display the menu.
	stty sane
	clear

	defaultchoice=
	printf "OmniOSce $title menu\n\n"
	for i in "${!menu[@]}"; do
		nameref item=menu[$i]
		printf "\t%d  %-40s" "$((i + 1))" "${item.menu_str}"
		[ -n "${item.current}" ] && printf "[`${item.current}`]"
		printf "\n"
		[ -n "${item.default}" ] && defaultchoice=$((i + 1))
	done
	# Return to previous menu should be the default choice.
	[ -z "$defaultchoice" ] && defaultchoice=$((i + 1))

	# Take an entry (by number). If multiple numbers are
	# entered, accept only the first one.
	input=""
	dummy=""
	print -n "\nPlease enter a number [$defaultchoice]: "
	read input dummy 2>/dev/null

	# If no input was supplied, select the default option
	[ -z "$input" -o "$input" = 0 ] && input=$defaultchoice
	return 0
}

show_menu()
{
	nameref menu="$1"

	if [ -n "$USE_DIALOG" ]; then
		show_dialog_menu "$@" || return 1
	else
		show_text_menu "$@" || return 1
	fi

	# Choice must only contain digits
	if [[ ${input} =~ [^1-9] || ${input} > ${#menu[@]} ]]; then
		return
	fi

	# Re-orient to a zero base.
	((input = input - 1))

	nameref item=menu[$input]

	if [ -n "$USE_DIALOG" -a -n "${item.dcmds}" ]; then
		for j in "${!item.dcmds[@]}"; do
			[ "${item.dcmds[$j]}" = 'back' ] && return 1
			${item.dcmds[$j]}
		done
	else
		for j in "${!item.cmds[@]}"; do
			[ "${item.cmds[$j]}" = 'back' ] && return 1
			${item.cmds[$j]}
		done
	fi
}

remove_config()
{
	typeset tag=$1
	if [ -f $INITIALBOOT ]; then
		sed -i "/BEGIN_$tag/,/END_$tag/d" $INITIALBOOT
		[ -s $INITIALBOOT ] || rm -f $INITIALBOOT
	fi
}

##############################################################################
# Networking

save_networking()
{
	remove_config NETWORK
	[ -n "$net_if" ] || return
	[ "$net_ifmode" = "static" -a -z "$net_ip" ] && return
	(
		echo '### BEGIN_NETWORK'
		echo "/sbin/ipadm create-if $net_if"
		if [ "$net_ifmode" = "static" ]; then
			echo "/sbin/ipadm create-addr -T static"\
			    "-a local=$net_ip $net_if/v4"
			[ -n "$net_gw" ] && \
			    echo "echo $net_gw > /etc/defaultrouter"
			if [ -n "$net_dns" ]; then
				rc=/etc/resolv.conf
				echo "/bin/rm -f $rc"
				[ -n "$net_domain" ] && \
				    echo "echo domain $net_domain >> $rc"
				echo "echo nameserver $net_dns >> $rc"
				echo '/bin/cp /etc/nsswitch.{dns,conf}'
			fi
		else
			echo "/sbin/ipadm create-addr -T dhcp $net_if/dhcp"
			# network/service should do this but let's be sure.
			echo '/bin/cp /etc/nsswitch.{dns,conf}'
			echo "/usr/sbin/svcadm restart network/service"
		fi
		echo '### END_NETWORK'
	) >> $INITIALBOOT
}

load_networking()
{
	net_if=
	net_ifmode=
	net_ip=
	net_gw=
	net_domain=
	net_dns=
	if [ -f $INITIALBOOT ]; then
		net_if=`grep create-if $INITIALBOOT | cut -d\  -f3`
		if egrep -s -- '-T static' $INITIALBOOT; then
			net_ifmode=static
			net_ip=`grep create-addr $INITIALBOOT | cut -d\  -f6 \
			    | cut -d= -f2`
			net_gw=`grep defaultrouter $INITIALBOOT | cut -d\  -f2`
		fi
		egrep -s -- '-T dhcp' $INITIALBOOT && net_ifmode=dhcp
		net_domain=`grep '^echo domain' $INITIALBOOT | cut -d\  -f3`
		net_dns=`grep '^echo nameserver' $INITIALBOOT | cut -d\  -f3`
	fi
	# Some sensible defaults
	[ -z "$net_ifmode" ] && net_ifmode=static
	[ -z "$net_if" ] \
	    && net_if="`/sbin/dladm show-phys -p -o link,media \
	       | grep ':Ethernet$' | head -1 | cut -d: -f1`"
	[ -z "$net_dns" ] && net_dns=80.80.80.80
}

clear_networking()
{
	remove_config NETWORK
	load_networking
}

show_networking()
{
	if [ ! -f $INITIALBOOT ]; then
		echo '<Unconfigured>'
	elif egrep -s -- '-T static' $INITIALBOOT; then
		echo 'Static'
	elif egrep -s -- '-T dhcp' $INITIALBOOT; then
		echo 'DHCP'
	else
		echo '<Unconfigured>'
	fi
}

mkiflist()
{
	# LINK         MEDIA                STATE      SPEED  DUPLEX    DEVICE
	# vioif0       Ethernet             up         1000   full      vioif0
	iflist=()
	i=0
	/sbin/dladm show-phys | sed 1d | while read line; do
		[[ $line = *Infiniband* ]] && continue
		set -- $line
		iflist[$i]=(link=$1 media=$2 state=$3 speed=$4 duplex=$5)
		((i = i + 1))
	done
}

dcfg_interface()
{
	mkiflist
	typeset -a args=()
	for i in "${!iflist[@]}"; do
		nameref item=iflist[$i]
		str=`printf "%10s %5s %6s %7s" \
		    "${item.media}" "${item.state}" \
		    "${item.speed}" "${item.duplex}"`

		[ "${item.link}" = "$net_if" ] && stat=on || stat=off
		args+=(${item.link} "$str" $stat)
	done

	dialog \
	    --title "Network interface" \
	    --colors \
	    --default-item $net_if \
	    --radiolist "\nSelect the network interface to be configured\n\Zn" \
		12 50 0 \
		"${args[@]}" 2> $tmpf
	stat=$?
	[ $stat -ne 0 ] && return
	net_if="`cat $tmpf`"
	rm -f $tmpf
}

cfg_interface()
{
	echo

	cat <<- EOM

-- The folowing network interfaces have been found on this system.
-- Select the interface which should be configured.

	EOM

	i=0
	/sbin/dladm show-phys | while read line; do
		[[ $line = *Infiniband* ]] && continue
		if [ $i -eq 0 ]; then
			printf "   $line\n"
		else
			printf "%2d %s\n" $i "$line"
			link=`echo $line | awk '{print $1}'`
			[ "$link" = "$net_if" ] && default=$i
		fi
		((i = i + 1))
	done

	echo

	while :; do
		read "_i?Network Interface [$default]: "
		[ -z "$_i" ] && break

		_net_if=`/sbin/dladm show-phys -p -o link | sed -n "${_i}p"`
		if [ -z "$_net_if" ]; then
			echo "No such interface, $_net_if"
			continue
		fi
		net_if="$_net_if"
		break
	done
}

show_interface()
{
	echo $net_if
}

cfg_ifmode()
{
	if [ "$net_ifmode" = "static" ]; then
		net_ifmode=dhcp
	else
		net_ifmode=static
	fi
}

show_ifmode()
{
	if [ "$net_ifmode" = "dhcp" ]; then
		echo "DHCP"
	else
		net_ifmode=static
		echo "Static"
	fi
}

dcfg_ip()
{
	def="${1:-1}"

	if [ "$net_ifmode" != "static" ]; then
		d_msg "Details will be retrieved via DHCP"
		return
	fi

	typeset _net_ip=$net_ip
	typeset _net_gw=$net_gw
	typeset _net_domain=$net_domain
	typeset _net_dns=$net_dns

	# Split IP into IP and prefix
	typeset _net_ip_ip=${net_ip%/*}
	#typeset _net_ip_prefix=${net_ip#*/}
	typeset _net_ip_prefix="`$IPCALC -m $_net_ip | cut -d= -f2`"

	typeset _lab_ip="      IP Address :"
	typeset _lab_prefix="  Netmask/Prefix :"
	typeset _lab_gw=" Default Gateway :"
	typeset _lab_domain="      DNS Domain :"
	typeset _lab_dns="      DNS Server :"

	while :; do
		extra=
		[ -n "$net_ip" ] && \
		    extra=" --extra-button --extra-label Delete "

		case $def in
			1)	def="$_lab_ip" ;;
			2)	def="$_lab_prefix" ;;
			3)	def="$_lab_gw" ;;
			4)	def="$_lab_domain" ;;
			5)	def="$_lab_dns" ;;
		esac

		dialog \
		    --title "Configure network" \
		    --colors \
		    --insecure \
		    --default-item "$def" \
		    $extra \
		    --form "\nEnter the network details below.\nThe netmask can be entered as a dotted quad (e.g. \Z7255.255.255.224\Zn) or as a prefix length (e.g. \Z7/27\Zn)\n\Zn" \
			18 50 0 \
			"$_lab_ip"	1 1 "$_net_ip_ip"     1 22 20 0 \
			"$_lab_prefix"	2 1 "$_net_ip_prefix" 2 22 20 0 \
			"$_lab_gw"	3 1 "$_net_gw"        3 22 20 0 \
			"$_lab_domain"	4 1 "$_net_domain"    4 22 20 0 \
			"$_lab_dns"	5 1 "$_net_dns"       5 22 20 0 \
		    2> $tmpf
		stat=$?
		if [ $stat -eq 3 ]; then
			# Extra button selected, clear configuration.
			clear_networking
			d_msg "Network configuration removed successfully."
			return
		fi
		[ $stat -ne 0 ] && return

		_net_ip_ip="`sed -n 1p < $tmpf`"
		_net_ip_prefix="`sed -n 2p < $tmpf`"
		_net_gw="`sed -n 3p < $tmpf`"
		_net_domain="`sed -n 4p < $tmpf`"
		_net_dns="`sed -n 5p < $tmpf`"
		rm -f $tmpf

		# Remove leading / on prefix if it was provided
		_net_ip_prefix=${_net_ip_prefix#/}
		# Remove suffixes that may have been provided erroneously
		_net_dns=${_net_dns%/*}
		_net_gw=${_net_gw%/*}

		# Reasonable default
		[ -z "$_net_ip_prefix" ] && _net_ip_prefix=255.255.255.0

		_net_ip="$_net_ip_ip/$_net_ip_prefix"

		##############################
		# IP validation

		def=1

		if [ -z "$_net_ip_ip" ]; then
			d_msg "IP Address must be provided."
			continue
		fi

		msg="`$IPCALC -c $_net_ip 2>&1`"
		if [ $? -ne 0 ]; then
			d_msg "$msg"
			continue
		fi

		typeset ip=$_net_ip_ip
		typeset prefix=`$IPCALC -p $_net_ip | cut -d= -f2`
		[ "$prefix" = 32 ] && prefix=255.255.255.0
		typeset network=`$IPCALC -n $ip/$prefix | cut -d= -f2`
		typeset xcast=`$IPCALC -b $ip/$prefix | cut -d= -f2`

		if [ "$ip" = "$network" ]; then
			d_msg "Entered IP is the reserved network address."
			continue
		fi
		if [ "$ip" = "$xcast" ]; then
			d_msg "Entered IP is the network broadcast address."
			continue
		fi

		##############################
		# GW validation

		def=3

		# Gateway is optional
		if [ -n "$_net_gw" ]; then
			msg="`$IPCALC -c $_net_gw 2>&1`"
			if [ $? -ne 0 ]; then
				d_msg "$msg"
				continue
			fi

			typeset ipprefix=`$IPCALC -p $_net_ip | cut -d= -f2`
			typeset ipnetwork=`$IPCALC -n $_net_ip | cut -d= -f2`
			typeset gwnetwork=`$IPCALC -n $_net_gw/$ipprefix \
			    | cut -d= -f2`

			if [ "$ipnetwork" != "$gwnetwork" ]; then
				d_msg "Gateway is not on the local network."
				continue
			fi
		fi

		##############################
		# Domain validation

		def=4

		if [ -n "$_net_domain" ] && \
		    ! echo $_net_domain | /usr/xpg4/bin/egrep -q \
'^[a-z0-9-]{1,63}\.(xn--)?([a-z0-9]+(-[a-z0-9]+)*\.)*[a-z]{2,63}$'
		then
			d_msg "$_net_domain is not a valid domain name."
			continue
		fi

		##############################
		# DNS validation

		def=5

		if [ -n "$_net_dns" ]; then
			msg="`$IPCALC -c $_net_dns 2>&1`"
			if [ $? -ne 0 ]; then
				d_msg "$msg"
				continue
			fi
		fi

		##############################
		# All ok
		net_ip="$ip/$prefix"
		net_gw="$_net_gw"
		net_domain="$_net_domain"
		net_dns="$_net_dns"

		break
	done
}

cfg_ipaddress()
{
	if [ "$net_ifmode" != "static" ]; then
		pause "IP address will be retrieved via DHCP"
		return
	fi
	cat <<- EOM

-- Enter the IP address as <ip>/<netmask> or <ip>/<prefixlen>.
-- To remove the configured IP address, enter - by itself.
-- Examples:
--    10.0.0.2/255.255.255.224
--    10.0.0.2/27

	EOM

	while :; do
		read "_net_ip?IP Address [$net_ip]: "
		[ -z "$_net_ip" ] && break
		[ "$_net_ip" = "-" ] && net_ip= && net_gw= && break

		# Validate - ipcalc prints a useful message in the error case
		$IPCALC -c $_net_ip || continue

		typeset ip=${_net_ip%/*}
		typeset prefix=`$IPCALC -p $_net_ip | cut -d= -f2`
		[ "$prefix" = 32 ] && prefix=24
		typeset network=`$IPCALC -n $ip/$prefix | cut -d= -f2`
		typeset xcast=`$IPCALC -b $ip/$prefix | cut -d= -f2`

		[ "$ip" = "$network" ] \
		    && echo "Entered IP is the reserved network address." \
		    && continue
		[ "$ip" = "$xcast" ] \
		    && echo "Entered IP is the network broadcast address." \
		    && continue

		net_ip="$ip/$prefix"
		break
	done
}

show_ipaddress()
{
	[ "$net_ifmode" = "static" ] && echo $net_ip || echo "via DHCP"
}

cfg_gateway()
{
	if [ "$net_ifmode" != "static" ]; then
		pause "Gateway address will be retrieved via DHCP"
		return
	fi
	if [ -z "$net_ip" ]; then
		pause "Please set an IP address first"
		return
	fi

	cat <<- EOM

-- Enter the IP address of the default gateway.
-- To remove the configured gateway, enter - by itself.

	EOM

	while :; do
		read "_net_gw?Default Gateway [$net_gw]: "
		[ -z "$_net_gw" ] && break
		[ "$_net_gw" = "-" ] && net_gw= && break

		# Validate - ipcalc prints a useful message in the error case
		$IPCALC -c $_net_gw || continue

		typeset gwip=${_net_gw%/*}
		typeset ipprefix=`$IPCALC -p $net_ip | cut -d= -f2`
		typeset ipnetwork=`$IPCALC -n $net_ip | cut -d= -f2`
		typeset gwnetwork=`$IPCALC -n $gwip/$ipprefix | cut -d= -f2`

		[ "$ipnetwork" != "$gwnetwork" ] \
		    && echo "Gateway is not on the local network." \
		    && continue

		net_gw="$gwip"
		break
	done
}

show_gateway()
{
	[ "$net_ifmode" = "static" ] && echo $net_gw || echo "via DHCP"
}

cfg_domain()
{
	if [ "$net_ifmode" != "static" ]; then
		pause "Domain name will be retrieved via DHCP"
		return
	fi
	cat <<- EOM

-- Enter the DNS domain name.
-- To remove the configured domain, enter - by itself.

	EOM

	while :; do
		read "_net_domain?DNS Domain [$net_domain]: "
		[ -z "$_net_domain" ] && break
		[ "$_net_domain" = "-" ] && net_domain= && break

		if ! echo $_net_domain | /usr/xpg4/bin/egrep -q \
'^[a-z0-9-]{1,63}\.(xn--)?([a-z0-9]+(-[a-z0-9]+)*\.)*[a-z]{2,63}$'
		then
			echo "$_net_domain is not a valid domain name."
			continue
		fi
		net_domain="$_net_domain"
		break
	done
}

show_domain()
{
	[ "$net_ifmode" = "static" ] && echo $net_domain || echo "via DHCP"
}

cfg_dns()
{
	if [ "$net_ifmode" != "static" ]; then
		pause "DNS servers will be retrieved via DHCP"
		return
	fi

	cat <<- EOM

-- Enter the IP address of the primary nameserver.
-- To remove the configured address, enter - by itself.

	EOM

	while :; do
		read "_net_dns?DNS Server [$net_dns]: "
		[ -z "$_net_dns" ] && break
		[ "$_net_dns" = "-" ] && net_dns= && break

		# Validate - ipcalc prints a useful message in the error case
		$IPCALC -c $_net_dns || continue

		# Remove any prefix that may have been entered in error
		net_dns=${_net_dns%/*}
		break
	done
}

show_dns()
{
	[ "$net_ifmode" = "static" ] && echo $net_dns || echo "via DHCP"
}

network_menu=( \
    (menu_str="Network Interface"					\
	cmds=("cfg_interface")						\
	dcmds=("dcfg_interface")					\
	current="show_interface"					\
    )									\
    (menu_str="Configuration Mode"					\
	cmds=("cfg_ifmode")						\
	current="show_ifmode"						\
    )									\
    (menu_str="IP Address"						\
	cmds=("cfg_ipaddress")						\
	dcmds=("dcfg_ip 1")						\
	current="show_ipaddress"					\
    )									\
    (menu_str="Default Gateway"						\
	cmds=("cfg_gateway")						\
	dcmds=("dcfg_ip 3")						\
	current="show_gateway"						\
    )									\
    (menu_str="DNS Domain"						\
	cmds=("cfg_domain")						\
	dcmds=("dcfg_ip 4")						\
	current="show_domain"						\
    )									\
    (menu_str="DNS Server"						\
	cmds=("cfg_dns")						\
	dcmds=("dcfg_ip 5")						\
	current="show_dns"						\
    )									\
    (menu_str="Return to main configuration menu"			\
	cmds=("save_networking" "back")							\
    )									\
)

cfg_networking()
{
	load_networking
	while show_menu network_menu "network configuration"; do
		:
	done
}

##############################################################################
# Create User

load_user()
{
	user_uid=
	user_pass=
	user_pfexec=
	user_sudo=
	user_sudo_nopw=
	if [ -f $INITIALBOOT ]; then
		user_uid=`grep useradd $INITIALBOOT | awk '{print $NF}'`
		user_sudo=`grep groupadd $INITIALBOOT | cut -d\  -f2`
		egrep -s 'Primary Admin' $INITIALBOOT && user_pfexec=y
		egrep -s 'NOPASSWD:' $INITIALBOOT && user_sudo_nopw=y
	fi
}

save_user()
{
	remove_config USER
	[ -z "$user_uid" ] && return
	(
		echo '### BEGIN_USER'
		echo "mkdir -p /export/home"
		echo "/usr/sbin/useradd -mZ -d /export/home/$user_uid $user_uid"
		echo "/usr/sbin/usermod -d /home/$user_uid $user_uid"
		echo "echo '$user_uid localhost:/export/home/&'"\
		    ">> /etc/auto_home"
		hash=`$PASSUTIL -H "$user_pass"`
		echo "sed -i 's|^$user_uid:[^:]*|$user_uid:$hash|' /etc/shadow"
		[ -n "$user_pfexec" ] && \
		    echo "/usr/sbin/usermod -P'Primary Administrator' $user_uid"
		if [ -n "$user_sudo" ]; then
			echo "/usr/sbin/groupadd $user_sudo"
			echo "/usr/sbin/usermod -G $user_sudo $user_uid"
			if [ -n "$user_sudo_nopw" ]; then
				echo "echo '%$user_sudo ALL=(ALL) "\
				    "NOPASSWD: ALL'"\
				    "> /etc/sudoers.d/group_$user_sudo"
			else
				echo "echo '%$user_sudo ALL=(ALL) ALL'"\
				    "> /etc/sudoers.d/group_$user_sudo"
			fi
		fi
		echo '### END_USER'
	) >> $INITIALBOOT
}

remove_user()
{
	user_uid=
	remove_config USER
}

dcfg_user()
{
	load_user

	def=1
	plab="        Password :"
	while :; do
		extra=
		[ -n "$user_uid" ] && \
		    extra=" --extra-button --extra-label Delete "

		dialog \
		    --title "Creating user" \
		    --colors \
		    --insecure \
		    --default-item "$def" \
		    $extra \
		    --mixedform "\nEnter the new user's details below\n\Zn" \
			12 50 0 \
			"        Username :"  1 1  "$user_uid"  1 22 20 0 0 \
			"$plab"               2 1  ""           2 22 20 0 1 \
			" Retype Password :"  3 1  ""           3 22 20 0 1 \
		    2> $tmpf
		stat=$?
		if [ $stat -eq 3 ]; then
			# Extra button selected, delete user.
			remove_user
			d_msg "User removed successfully."
			return
		fi
		user_uid="`sed -n 1p < $tmpf`"
		[ -z "$user_uid" -o $stat -ne 0 ] && return
		user_pass="`sed -n 2p <$tmpf`"
		user_pass2="`sed -n 3p <$tmpf`"
		rm -f $tmpf

		if [[ ! $user_uid =~ ^[a-z][-a-z0-9]*$ ]]; then
			d_msg "$user_uid is not a valid username."
			def=1
			continue
		fi

		if [ -z "$user_pass" ]; then
			d_msg "A password must be entered."
			def="$plab"
			continue
		fi

		if [ "$user_pass" != "$user_pass2" ]; then
			d_msg "Entered passwords do not match."
			def="$plab"
			continue
		fi
		break
	done

	if [ -n "$user_uid" ]; then
		dialog \
		    --title "Creating user" \
		    --colors \
		    --no-tags \
		    --checklist "\nSelect user privileges\n\Zn" 12 50 0 \
			pfexec "Grant 'Primary Administrator' role" on \
			sudo   "Grant 'sudo' access" off \
			sudopw "  (without password?)" off \
		    2> $tmpf
		stat=$?
		[ $stat -ne 0 ] && return
		user_pfexec=
		user_sudo=
		user_sudo_nopw=
		for f in `cat $tmpf`; do
		    case $f in
			pfexec)	user_pfexec=y ;;
			sudo)	user_sudo=sudo ;;
			sudopw)	user_sudo_nopw=y ;;
		    esac
		done
		rm -f $tmpf
	fi

	save_user

	d_msg "User $user_uid created successfully."
}

cfg_user()
{
	load_user

	if [ -n "$user_uid" ]; then
		cat <<- EOM

-- Choose a new username or to remove the user configuration, enter - at the
-- prompt.

		EOM
	fi

	while :; do
		read "_uid?Username [$user_uid]: "
		if [ "$_uid" = "-" ]; then
			remove_user
			return
		fi
		if [ -z "$_uid" ]; then
			[ -z "$user_uid" ] && break
			_uid=$user_uid
		fi

		if [[ ! $_uid =~ ^[a-z][-a-z0-9]*$ ]]; then
			echo "$_uid is not a valid username."
			continue
		fi
		user_uid=$_uid
		break
	done

	while :; do
		user_pass=
		while [ -z "$user_pass" ]; do
			stty -echo
			read "user_pass?Password: "
			echo
			stty echo
		done
		stty -echo
		read "user_pass2?   Again: "
		echo; stty echo

		if [ "$user_pass" != "$user_pass2" ]; then
			echo "-- Passwords do not match."
			continue
		fi
		break
	done

	cat <<- EOM

-- The new user can be automatically assigned to the Primary Administrator
-- role so that commands can be executed with root privileges via 'pfexec'

	EOM

	ask "Grant 'Primary Administrator' role to user?" \
	    && user_pfexec=y || user_pfexec=

	cat <<- EOM

-- If you wish, a new group can be created with access to sudo and the new
-- user can be placed into that group during installation.

	EOM

	if ask "Place user in new group and grant sudo?"; then
		[ -n "$user_sudo" ] && _default=$user_sudo || _default=sudo
		while :; do
			read "_grp?Group Name [$_default]: "
			if [ -z "$_grp" ]; then
				user_sudo=$_default
				break
			fi

			if [[ ! $_grp =~ ^[a-z][a-z]*$ ]]; then
				echo "$_grp is not a valid group name."
				continue
			fi

			user_sudo=$_grp
			break
		done
		ask "Require password for sudo?" \
		    && user_sudo_nopw= || user_sudo_nopw=y
	fi

	save_user
}

show_user()
{
	load_user
	tag='<none>'
	if [ -n "$user_uid" ]; then
		tag=$user_uid
	fi
	[ -n "$user_pfexec" ] && tag="$tag/admin"
	[ -n "$user_sudo" ] && tag="$tag/sudo"
	echo $tag
}

##############################################################################
# Set Root Password

cfg_rootpw()
{
	while :; do
		root_pass=
		while [ -z "$root_pass" ]; do
			stty -echo
			read "root_pass?Root Password: "
			echo; stty echo
		done
		stty -echo
		read "root_pass2?        Again: "
		echo; stty echo

		if [ "$root_pass" != "$root_pass2" ]; then
			echo "-- Passwords do not match."
			continue
		fi
		break
	done

	store_rootpw "$root_pass"

	pause "The root password has been set"
}

dcfg_rootpw()
{
	while :; do

		dialog \
		    --title "Setting root password" \
		    --colors \
		    --insecure \
		    --mixedform "\nEnter the new password twice below\n\Zn" \
			12 50 0 \
			"        Password :"  1 1  ""  1 22 20 0 1 \
			" Retype Password :"  2 1  ""  2 22 20 0 1 \
		    2> $tmpf
		stat=$?
		root_pass="`head -1 $tmpf`"
		root_pass2="`tail -1 $tmpf`"
		rm -f $tmpf
		[ -z "$root_pass" -o $stat -ne 0 ] && return

		if [ "$root_pass" != "$root_pass2" ]; then
			d_msg "Entered passwords do not match."
			continue
		fi
		break
	done

	store_rootpw "$root_pass"

	d_msg "The root password has been set."
}

store_rootpw()
{
	typeset arg="$1"

	remove_config ROOTPW
	(
		echo "### BEGIN_ROOTPW"
		hash=`$PASSUTIL -H "$arg"`
		echo "sed -i 's|^root:[^:]*|root:$hash|' /etc/shadow"
		echo "### END_ROOTPW"
	) >> $INITIALBOOT

}

show_rootpw()
{
	[ -f $INITIALBOOT ] && egrep -s ROOTPW $INITIALBOOT \
	    && echo "********" || echo "<blank>"
}

##############################################################################
# Virtual Terminals

cfg_vtdaemon()
{
	if [ -f $INITIALBOOT ] && egrep -s vtdaemon $INITIALBOOT; then
		remove_config VTDAEMON
	else
		# Add configuration
		cat << EOM >> $INITIALBOOT
### BEGIN_VTDAEMON
/usr/sbin/svcadm enable vtdaemon
for i in \`seq 2 6\`; do
	/usr/sbin/svcadm enable console-login:vt\$i
done
/usr/sbin/svccfg -s vtdaemon setprop options/hotkeys=true
/usr/sbin/svccfg -s vtdaemon setprop options/secure=false
/usr/sbin/svcadm refresh vtdaemon
/usr/sbin/svcadm restart vtdaemon
### END_VTDAEMON
EOM
	fi
}

show_vtdaemon()
{
	[ -f $INITIALBOOT ] && egrep -s VTDAEMON $INITIALBOOT \
	    && echo "Enabled" || echo "Disabled"
}

##############################################################################
# SSH Server

cfg_sshd()
{
	if [ -f $ALTROOT/etc/svc/profile/site/nossh.xml ]; then
		rm -f $ALTROOT/etc/svc/profile/site/nossh.xml
	else
		[ -d  $ALTROOT/etc/svc/profile/site ] \
		    || mkdir -p  $ALTROOT/etc/svc/profile/site
		cp /kayak/nossh.xml $ALTROOT/etc/svc/profile/site/nossh.xml
	fi
}

show_sshd()
{
	[ -f $ALTROOT/etc/svc/profile/site/nossh.xml ] \
	    && echo "Disabled" || echo "Enabled"
}

##############################################################################

# Main menu
main_menu=( \
    (menu_str="Configure Networking"					\
	cmds=("cfg_networking")						\
	current="show_networking"					\
    )									\
    (menu_str="Create User"						\
	cmds=("cfg_user")						\
	dcmds=("dcfg_user")						\
	current="show_user"						\
    )									\
    (menu_str="Set Root Password"					\
	cmds=("cfg_rootpw")						\
	dcmds=("dcfg_rootpw")						\
	current="show_rootpw"						\
    )									\
    (menu_str="SSH Server"						\
	cmds=("cfg_sshd")						\
	current="show_sshd"						\
    )									\
    (menu_str="Virtual Terminals"					\
	cmds=("cfg_vtdaemon")						\
	current="show_vtdaemon"						\
    )									\
    (menu_str="Return to main menu"					\
	cmds=("exit")							\
    )									\
)

while show_menu main_menu configuration; do
	:
done

# Vim hints
# vim:fdm=marker
