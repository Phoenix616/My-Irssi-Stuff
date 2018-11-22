# Copyright (c) 2010 Adam James <atj@pulsewidth.org.uk>
# Copyright (c) 2015 Igor Duarte Cardoso <igordcard@gmail.com>
# Copyright (c) 2016 Max Lee <mail@moep.tv>

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

# Changelog:
# 1.2 - add config option to specify which channels should send notifications
# 1.1 - compress multiple messages into one
# 1.0 - initial release, based on email_msgs 1.0:
#   * support for public messages as well (with/without mentions);
#   * support for own messages as well;
#   * configuration options to select what messages should be emailed:
#     - public received;
#     - private received;
#     - private sent;
#     - public sent;
#     - public mentions received.
#   * configuration option to choose whether the user must be away or not;
#   * configuration option for the bot api key;
#   * configuration option for the destination chat id;
#   * configuration option to activate detailed info:
#     - currently only to send the user's hostname (for spam tracking e.g.).

use strict;
use vars qw($VERSION %IRSSI);

use Irssi;
use POSIX qw(strftime);

#use Net::SSL (); # From Crypt-SSLeay
use LWP::UserAgent;

use Parallel::ForkManager;

my $pm = Parallel::ForkManager->new(5);

$VERSION = '1.2';
%IRSSI = (
	authors => 'Max Lee',
	contact => 'mail@moep.tv',
	url =>
		"https://moep.tv",
	name => 'telegram_msgs',
	description =>
		"Send you messages via telegram while you're away or not. " .
		"Works for both public mentions and private messages." .
		"When away, it is very useful in combination with proxy_screen_away. " .
		"Based on email_msgs, with advanced features and options. ",
	license => 'MIT',
);

my $FORMAT = $IRSSI{'name'} . '_crap';
my @msgs = ();
my $notify_task = undef;

Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_away_only', '0');
Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_detailed', '1');
Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_delay', '1000');
Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_notify_after', '10');
Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_pub_r_msgs', '0');
Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_pri_r_msgs', '1');
Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_pub_s_msgs', '0');
Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_pri_s_msgs', '0');
Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_mentions', '1');

Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_notify_channels', '');
Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_api_key', '');
Irssi::settings_add_str('telegram_msgs', $IRSSI{'name'} . '_to_chat_id', '');

# user configurable variables (1->yes; 0->no):
##############################################
# whether the script should work only when away:
my $away_only    = Irssi::settings_get_str($IRSSI{'name'} . '_away_only');
# include detailed info like the hostname of the sender:
my $detailed     = Irssi::settings_get_str($IRSSI{'name'} . '_detailed');
# delay (in milliseconds) a message should wait for additional ones before sending (0 disables it):
my $delay        = Irssi::settings_get_str($IRSSI{'name'} . '_delay');
# after how many messages should we notify even when more are comming in during the delay (0 disables it):
my $notify_after = Irssi::settings_get_str($IRSSI{'name'} . '_notify_after');
# whether public messages received (including mentions) should be send:
my $pub_r_msgs   = Irssi::settings_get_str($IRSSI{'name'} . '_pub_r_msgs');
# whether private messages received should be send:
my $pri_r_msgs   = Irssi::settings_get_str($IRSSI{'name'} . '_pri_r_msgs');
# whether public messages sent should be send:
my $pub_s_msgs   = Irssi::settings_get_str($IRSSI{'name'} . '_pub_s_msgs');
# whether private messages sent should be send:
my $pri_s_msgs   = Irssi::settings_get_str($IRSSI{'name'} . '_pri_s_msgs');
# whether public mentions received should be send (when $pub_r_msgs=0):
my $mentions     = Irssi::settings_get_str($IRSSI{'name'} . '_mentions');
##############################################
# Configurable strings:
##############################################
# Channels where all messages should be send to telegram
my $notifyChannels =  Irssi::settings_get_str($IRSSI{'name'} . '_notify_channels');

Irssi::theme_register([
	$FORMAT,
	'{line_start}{hilight ' . $IRSSI{'name'} . ':} $0'
]);

# your bot's api key:
my $api_key = Irssi::settings_get_str($IRSSI{'name'} . '_api_key');
# your destination chat id, get it via messaging your bot and 
# opening https://api.telegram.org/bot{your api key}/getUpdates
my $to_chat_id = Irssi::settings_get_str($IRSSI{'name'} . '_to_chat_id');


return if (!check_setup($api_key, $to_chat_id));	

sub handle_ownprivmsg {
	my ($server, $message, $target, $orig_target) = @_;

	if ($server->{usermode_away} || !$away_only) {
		send_msg($server, $message, $server->{nick}, "you", "\@$target");
	}
}

sub handle_ownpubmsg {
	my ($server, $message, $target) = @_;

	if ($server->{usermode_away} || !$away_only) {
		send_msg($server, $message, $server->{nick}, "you", $target);
	}
}

sub handle_privmsg {
	my ($server, $message, $user, $address) = @_;

	if ($server->{usermode_away} || !$away_only) {
		send_msg($server, $message, $user, $address, "\@$user");
	}
}

sub handle_pubmsg {
	my ($server, $message, $user, $address, $target) = @_;

	if ($server->{usermode_away} && index($notifyChannels, $target) >= 0) {
		send_msg($server, $message, $user, $address, $target);
	} elsif ($server->{usermode_away} || !$away_only) {
		if (index($message,$server->{nick}) >= 0 || $pub_r_msgs) {
			send_msg($server, $message, $user, $address, $target);
		}
	}

}

sub check_setup {
	my ($api_key, $to_chat_id) = @_;

	if ($api_key eq "") {
		Irssi::printformat(MSGLEVEL_CLIENTCRAP, $FORMAT, $IRSSI{'name'} . ' was not setup right, please set the option ' . $IRSSI{'name'} . '_api_key');
		return 0;
	}
	
	if ($to_chat_id eq "") {
		Irssi::printformat(MSGLEVEL_CLIENTCRAP, $FORMAT, $IRSSI{'name'} . ' was not setup right, please set the option ' . $IRSSI{'name'} . '_to_chat_id');
		return 0;
	}
	return 1;
}

sub send_msg {
	my ($server, $message, $user, $address, $target) = @_;

	if ($target =~ /^@/) {
		$target = "@";
	}

	my $tg_msg = '[IRC] ' . $target .' | ' .  $user . ': ' . $message;

	if ($delay == 0) {
		api_call($tg_msg);
	} else {
		# Remove the old notify task
		if (defined $notify_task) {
			Irssi::timeout_remove($notify_task);
			undef $notify_task;
		}

		# add msg to messages array
		push @msgs, $tg_msg;

		# check if we should force send messages after a specific number of messages in the cache 
		if ($notify_after > 0 && scalar @msgs >= $notify_after) {
			process_msgs();
		} else {
			$notify_task = Irssi::timeout_add_once($delay, 'process_msgs', '')
		}
	}
}

sub process_msgs {
	if (scalar @msgs <= 0) {
		return;
	}
	my $tg_msg = join("\n", @msgs);
	@msgs = ();
	api_call($tg_msg);
}

sub api_call {
	my ($text) = @_;

	use URI::Escape;	
	my $escaped = uri_escape($text);

#	foreach (1) {
#		my $pid = $pm->start:# and next;

		my $ua = LWP::UserAgent->new();
		my $req = HTTP::Request->new('GET','https://api.telegram.org/bot' . $api_key . '/sendMessage?chat_id=' . $to_chat_id . '&text=' . $escaped);
#		Irssi::printformat(MSGLEVEL_CLIENTCRAP, $FORMAT, $urla);
		my $res = $ua->request($req);
#                Irssi::printformat(MSGLEVEL_CLIENTCRAP, $FORMAT, 'Request returned ' . $res->content());
#		$pm->finish;
#	}
}

if ($pub_r_msgs || $mentions) {
	Irssi::signal_add_last("message public", "handle_pubmsg");
}
if ($pri_r_msgs) {
	Irssi::signal_add_last("message private", "handle_privmsg");
}
if ($pub_s_msgs) {
	Irssi::signal_add_last("message own_public", "handle_ownpubmsg");
}
if ($pri_s_msgs) {
	Irssi::signal_add_last("message own_private", "handle_ownprivmsg");
}
