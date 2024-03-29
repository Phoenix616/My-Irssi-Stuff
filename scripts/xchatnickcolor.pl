use strict;
use Irssi 20020101.0250 ();
use vars qw($VERSION %IRSSI); 
$VERSION = "1.1.2";
%IRSSI = (
    authors     => "Timo Sirainen, Ian Peters, Max Lee",
    contact => "tss\@iki.fi, Max Lee: mail\@moep.tv", 
    name        => "Nick Color",
    description => "assign a different color for each nick",
    license => "Public Domain",
    url     => "http://irssi.org/",
    changed => "2023-05-13T14:18+0100"
);

my %saved_colors;
my %session_colors = {};
#my @colors = qw/ 2 3 4 5 6 7 9 10 11 12 13 14 15/;
my @colors = qw/ 2 3 5 6 7 10/;

sub load_colors {
  open COLORS, "$ENV{HOME}/.irssi/saved_colors";

  while (<COLORS>) {
    # I don't know why this is necessary only inside of irssi
    my @lines = split "\n";
    foreach my $line (@lines) {
      my($nick, $color) = split ":", $line;
      $saved_colors{$nick} = $color;
    }
  }

  close COLORS;
}

sub save_colors {
  open COLORS, ">$ENV{HOME}/.irssi/saved_colors";

  foreach my $nick (keys %saved_colors) {
    print COLORS "$nick:$saved_colors{$nick}\n";
  }

  close COLORS;
}

# If someone we've colored (either through the saved colors, or the hash
# function) changes their nick, we'd like to keep the same color
# associated
# with them (but only in the session_colors, ie a temporary mapping).

sub sig_nick {
  my ($server, $newnick, $nick, $address) = @_;
  my $color;

  $newnick = substr ($newnick, 1) if ($newnick =~ /^:/);

  if ($color = $saved_colors{$nick}) {
    $session_colors{$newnick} = $color;
  } elsif ($color = $session_colors{$nick}) {
    $session_colors{$newnick} = $color;
  }
}

# This gave reasonable distribution values when run across
# /usr/share/dict/words

sub simple_hash {
  my ($string) = @_;
  chomp $string;
  my @chars = split //, $string;
  my $counter;

  foreach my $char (@chars) {
    $counter += ord $char;
  }

  $counter = $colors[$counter % (0+@colors)];

  return $counter;
}

sub sig_public {
  my ($server, $msg, $nick, $address, $target) = @_;
  my $chanrec = $server->channel_find($target);
  return if not $chanrec;
  my $nickrec = $chanrec->nick_find($nick);
  my $nickmode = "";
  if ($nickrec) {
    $nickmode = $nickrec->{op} ? "@" : $nickrec->{voice} ? "+" : "";
  }
  # Has the user assigned this nick a color?
  my $color = $saved_colors{$nick};

  # Have -we- already assigned this nick a color?
  if (!$color) {
    $color = $session_colors{$nick};
  }

  # Let's assign this nick a color
  if (!$color) {
    $color = simple_hash $nick;
    $session_colors{$nick} = $color;
  }

  $color = "0".$color if ($color < 10);
  $server->command('/^format pubmsg %w$2'.chr(3).$color.'$[-11]0%K|%n $1');
  $server->command('/^format action_core %m          * %K|'.chr(3).$color.' $*%w');
  $server->command('/^format pubmsg_me %w$2'.chr(3).$color.'$[-11]0%K|%Y $1');
  $server->command('/^format pubmsg_me_channel %w$3$2'.chr(3).$color.'$[-11]0{msgchannel $1}%K|%Y $2');
  $server->command('/^format pubmsg_hilight %w$0$3'.chr(3).$color.'$[-11]1%K|%Y $2');
  $server->command('/^format pubmsg_hilight_channel %w$0$4'.chr(3).$color.'$[-11]1{msgchannel $2}%K| %Y $3');
 # $server->command('/^format action_public {pubaction
 # '.chr(3).$color.'$0}$1');
}

sub cmd_color {
  my ($data, $server, $witem) = @_;
  my ($op, $nick, $color) = split " ", $data;

  $op = lc $op;

  if (!$op) {
    Irssi::print ("No operation given");
  } elsif ($op eq "save") {
    save_colors;
  } elsif ($op eq "set") {
    if (!$nick) {
      Irssi::print ("Nick not given");
    } elsif (!$color) {
      Irssi::print ("Color not given");
    } elsif ($color < 0 || $color > 15) {
      Irssi::print ("Color must be between 0 and 15 inclusive");
    } else {
      $saved_colors{$nick} = $color;
      Irssi::print ("Set color of $nick to ". chr (3) . "$color$color");
    }
  } elsif ($op eq "clear") {
    if (!$nick) {
      Irssi::print ("Nick not given");
    } else {
      delete ($saved_colors{$nick});
    }
  } elsif ($op eq "list") {
    Irssi::print ("\nSaved Colors:");
    foreach my $nick (keys %saved_colors) {
      Irssi::print (chr (3) . "$saved_colors{$nick}$nick" .
          chr (3) . "1 ($saved_colors{$nick})");
    }
  } elsif ($op eq "preview") {
    Irssi::print ("\nAvailable colors:");
    foreach my $i (2..14) {
      Irssi::print (chr (3) . "$i" . "Color #$i");
    }
  }
}

load_colors;

Irssi::command_bind('color', 'cmd_color');

Irssi::signal_add('message public', 'sig_public');
Irssi::signal_add('event nick', 'sig_nick');
