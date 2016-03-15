use Irssi;
use strict;
use FileHandle;

use vars qw($VERSION %IRSSI);

$VERSION = "0.9.8.1 - 1.0";
%IRSSI = (
    authors     => 'Phoenix616 <mail@moep.tv>, Andreas \'ads\' Scherbaum <ads@wars-nicht.de>',
    name        => 'proxy_and_screen_away',
    description => 'set (un)away, if screen and proxy is attached/detached',
    license     => 'GPL v2',
    url         => 'none',
);

# proxy_screen_away irssi module
#
# written by Andreas 'ads' Scherbaum <ads@ufp.de>
# extended with proxy support by Phoenix616 <mail@moep.tv>
#
# changes:
#  13.03.2016 added support for proxies
#  20.12.2014 fix the bug when screenname is changed during the session
#  07.02.2004 fix error with away mode
#             thanks to Michael Schiansky for reporting and fixing this one
#  07.08.2004 new function for changing nick on away
#  24.08.2004 fixing bug where the away nick was not storedcorrectly
#             thanks for Harald Wurpts for help debugging this one
#  17.09.2004 rewrote init part to use $ENV{'STY'}
#  05.12.2004 add patch for remember away state
#             thanks to Jilles Tjoelker <jilles@stack.nl>
#             change "chatnet" to "tag"
#  18.05.2007 fix '-one' for SILC networks
#
#
# usage:
#
# put this script into your autorun directory and/or load it with
#  /SCRIPT LOAD <name>
#
# there are 5 settings available:
#
# /set screen_away_active ON/OFF/TOGGLE
# /set screen_away_repeat <integer>
# /set screen_away_message <string>
# /set screen_away_window <string>
# /set screen_away_nick <string>
#
# active means, that you will be only set away/unaway, if this
#   flag is set, default is ON
# repeat is the number of seconds, after the script will check the
#   screen status again, default is 5 seconds
# message is the away message sent to the server, default: not here ...
# window is a window number or name, if set, the script will switch
#   to this window, if it sets you away, default is '1'
# nick is the new nick, if the script goes away
#   will only be used it not empty
#
# normal you should be able to rename the script to something other
# than 'screen_away' (as example, if you dont like the name) by simple
# changing the 'name' parameter in the %IRSSI hash at the top of this script


# variables
my $timer_name = undef;
my $screen_status = 0;
# 0 = init
# 1 = detached
# 2 = attached
my %old_nicks = ();
my %away = ();
my %proxy = ();

# Register formats
Irssi::theme_register(
[
 'screen_away_crap', 
 '{line_start}{hilight ' . $IRSSI{'name'} . ':} $0'
]);

# if we are running
my $screen_away_used = 0;

# try to find out, if we are running in a screen
# (see, if $ENV{STY} is set
if (!defined($ENV{STY})) {
  # just return, we will never be called again
  Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'screen_away_crap',
    "could not open status file for parent process (pid: " . getppid() . "): $!");
  return;
}

my ($socket_pid, $socket_name, $socket_path);

# search for socket
# normal we could search the socket file, ... if we know the path
# but so we have to call one time the screen executable
# disable locale
# the quotes around C force perl 5.005_03 to use the shell
# thanks to Jilles Tjoelker <jilles@stack.nl> for pointing this out
my $socket = `LC_ALL="C" screen -ls`;



my $running_in_screen = 0;
# locale doesnt seems to be an problem (yet)
if ($socket !~ /^No Sockets found/s) {
  # ok, should have only one socket
  # $STY won't change if sessionname is changed during session
  # therefore first find the pid and use that to find the actual sessionname
  $socket_pid = substr($ENV{'STY'}, 0, index($ENV{'STY'}, '.'));
  $socket_path = $socket;
  $socket_path =~ s/^.*\d+ Sockets? in ([^\n]+)\..*$/$1/s;
  $socket_name = $socket;
  $socket_name =~ s/^.+?($socket_pid\.\S+).+$/$1/s;
  if (length($socket_path) != length($socket)) {
    # only activate, if string length is different
    # (to make sure, we really got a dir name)
    $screen_away_used = 1;
  } else {
    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'screen_away_crap',
      "error reading screen informations from:");
    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'screen_away_crap',
      "$socket");
    return;
  }
}

# last check
if ($screen_away_used == 0) {
  # we will never be called again
  return;
}

# build complete socket name
$socket = $socket_path . "/" . $socket_name;

# register config variables
Irssi::settings_add_bool('misc', $IRSSI{'name'} . '_active', 1);
Irssi::settings_add_int('misc', $IRSSI{'name'} . '_repeat', 5);
Irssi::settings_add_str('misc', $IRSSI{'name'} . '_message', "not here ...");
Irssi::settings_add_str('misc', $IRSSI{'name'} . '_window', "1");
Irssi::settings_add_str('misc', $IRSSI{'name'} . '_nick', "");

# init process
screen_away();

# screen_away()
#
# check, set or reset the away status
#
# parameter:
#   none
# return:
#   0 (OK)
sub screen_away {
  my ($away, @screen, $screen);

  # only run, if activated
  if (Irssi::settings_get_bool($IRSSI{'name'} . '_active') == 1) {
    if ($screen_status == 0) {
      # display init message at first time
      Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'screen_away_crap',
        "activating $IRSSI{name} (interval: " . Irssi::settings_get_int($IRSSI{name} . '_repeat') . " seconds)");
    }
    # get actual screen status
    my @screen = stat($socket);
    # 00100 is the mode for "user has execute permissions", see stat.h
    if (($screen[2] & 00100) == 0) {
      # no execute permissions, Detached
      if($screen_status != 1) {
        $screen_status = 1;
        set_away();
      }
    } else {
      # execute permissions, Attached
      if($screen_status != 2) {
        $screen_status = 2;
        set_unaway();
      }
    }
  }
  # but everytimes install a new timer
  register_screen_away_timer();
  return 0;
}

# register_screen_away_timer()
#
# remove old timer and install a new one
#
# parameter:
#   none
# return:
#   none
sub register_screen_away_timer {
  if (defined($timer_name)) {
    # remove old timer, if defined
    Irssi::timeout_remove($timer_name);
  }
  # add new timer with new timeout (maybe the timeout has been changed)
  $timer_name = Irssi::timeout_add(Irssi::settings_get_int($IRSSI{name} . '_repeat') * 1000, 'screen_away', '');
}

# client_connect()
#
# called when a new client connects to the proxy
#
# parameter:
#   client
# return:
#   none
sub client_connect {
  my ($client) = @_;
  $proxy{$client->{server}->{tag}}++;
  if($proxy{$client->{server}->{tag}} == 1) {
    set_unaway($client->{server}->{tag});
  }
}

# client_disconnect()
#
# called when a new client disconnects from the proxy
#
# parameter:
#   client
# return:
#   none
sub client_disconnect {
  my ($client) = @_;
  $proxy{$client->{server}->{tag}}--;
  if($proxy{$client->{server}->{tag}} == 0) {
    set_away($client->{server}->{tag});
  }
}

Irssi::signal_add_last('proxy client connected', 'client_connect');
Irssi::signal_add_last('proxy client disconnected', 'client_disconnect');

# set_away()
#
# set irssi to away (optionally only on specific server)
#
# parameter:
#   servername (optional)
# return:
#   none
sub set_away {
  my ($servername) = @_;
  if (!defined $servername) {
    $servername = "ALL";
  }
  # only set away if screen is not attached
  if ($screen_status != 2) {
    # set away
    my $message = Irssi::settings_get_str($IRSSI{name} . '_message');
    if (length($message) == 0) {
      # we have to set a message or we wouldnt go away
      $message = "not here ...";
    }
    my ($server, $changed);
    foreach $server (Irssi::servers()) {
      if ($server->{tag} != $servername and $servername != "ALL") {
        next;
      }
      
      if (!$server->{usermode_away}) {
        $changed ++;
        # user isnt yet away
        $away{$server->{tag}} = 0;
        $server->command("AWAY " . (($server->{chat_type} ne 'SILC') ? "-one " : "") . "$message") if (!$server->{usermode_away});
        if (length(Irssi::settings_get_str($IRSSI{name} . '_nick')) > 0) {
          # only change, if actual nick isnt already the away nick
          if (Irssi::settings_get_str($IRSSI{name} . '_nick') ne $server->{nick}) {
            # keep old nick
            $old_nicks{$server->{tag}} = $server->{nick};
            # set new nick
            $server->command("NICK " . Irssi::settings_get_str($IRSSI{name} . '_nick'));
          }
        }
      } else {
        # user is already away, remember this
        $away{$server->{tag}} = 1;
      }
    }
    
    if ($changed > 0) {    
      if (length(Irssi::settings_get_str($IRSSI{name} . '_window')) > 0) {
        # if length of window is greater then 0, make this window active
        Irssi::command('window goto ' . Irssi::settings_get_str($IRSSI{name} . '_window'));
      }
      Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'screen_away_crap',
        "Set away");
    }
  }
}
# set_unaway()
#
# set irssi to unaway (optionally only on specific server)
#
# parameter:
#   servername (optional)
# return:
#   none
sub set_unaway {
  my ($servername) = @_;
  if (!defined $servername) {
    $servername = "ALL";
  }
  my ($server,$changed);
  foreach $server (Irssi::servers()) {
    if ($server->{tag} == $servername or $servername == "ALL") {     
      if ($server->{usermode_away}) {  
        $changed ++;
        # unset away    
        $server->command("AWAY" . (($server->{chat_type} ne 'SILC') ? " -one" : ""));
      } else {        
        # already back      
        $away{$server->{tag}} = 0;
      }
    }
    
    if (defined($old_nicks{$server->{tag}}) and length($old_nicks{$server->{tag}}) > 0) {
      # set old nick
      $server->command("NICK " . $old_nicks{$server->{tag}});
      $old_nicks{$server->{tag}} = "";
    }
  }
  
  if ($changed > 0) {       
    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'screen_away_crap', "Reset away");
  }
}
