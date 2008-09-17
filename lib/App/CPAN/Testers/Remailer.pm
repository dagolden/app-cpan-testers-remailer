# Copyright (c) 2008 by David Golden. All rights reserved.
# Licensed under Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License was distributed with this file or you may obtain a 
# copy of the License from http://www.apache.org/licenses/LICENSE-2.0

package App::CPAN::Testers::Remailer;
use 5.006;
use strict;
use warnings;

our $VERSION = '0.01';
$VERSION = eval $VERSION; ## no critic

use Safe;
use Email::Simple;
use Email::Address;
use File::Basename qw/basename/;
use LWP::Simple;
use Net::DNS qw/mx/;
use Getopt::Long;
use POE qw( 
  Component::Client::NNTP::Tail
  Component::Client::SMTP
);

#--------------------------------------------------------------------------#
# FIXED PARAMETERS
#--------------------------------------------------------------------------#

my $nntpserver  = "nntp.perl.org";
my $group       = "perl.cpan.testers";

#--------------------------------------------------------------------------#
# MAIN APPLICATION CODE
#--------------------------------------------------------------------------#

sub run {
  my ($class) = shift;

  $0 = basename($0);

  #--------------------------------------------------------------------------#
  # Parameter handling
  #--------------------------------------------------------------------------#

  my ($author,@grades,$help);
  my $mirror      = "http://cpan.pair.com/";
  my $smtp        = [ mx('perl.org') ]->[0]->exchange; # maybe change to your ISP's server
  my $checksum_path;

  GetOptions( 
    'author=s'  => \$author,
    'grade=s'   => \@grades,
    'smtp=s'    => \$smtp,
    'mirror=s'  => \$mirror,
    'help'      => \$help
  );

  die << "END_USAGE" if $help || ! ( $author && @grades );
Usage: $0 OPTIONS

Options:
  --author=AUTHORID     CPAN author ID (required)

  --grade=GRADE         PASS, FAIL, UNKNOWN or NA (required, multiple ok)
  
  --smtp=SERVER         SMTP relay server; defaults to mx.perl.org
  
  --mirror=MIRROR       CPAN mirror; defaults to http://cpan.pair.com/

  --help                this usage info
END_USAGE

  $author = uc $author; # DWIM
  if ($author =~ /^(([a-z])[a-z])[a-z]+$/i) {
    $checksum_path="authors/id/$2/$1/$author/CHECKSUMS";
  }
  else {
    die "$0: '$author' doesn't seem to be a proper CPAN author ID\n";
  }

  for my $g ( @grades ) {
    $g = uc $g; # DWIM
    die "$0: '$g' is not a valid grade (PASS, FAIL, UNKNOWN or NA)\n"
      unless $g =~ /^(?:PASS|FAIL|UNKNOWN|NA)$/;
  }

  # make sure mirror ends with slash
  $mirror =~ s{/$}{};
  $mirror .= "/";

  #--------------------------------------------------------------------------#
  # Launch POE sessions
  #--------------------------------------------------------------------------#

  POE::Component::Client::NNTP::Tail->spawn(
    NNTPServer  => $nntpserver,
    Group       => $group,
  );

  POE::Session->create(
    package_states => [
      $class => [qw(_start refresh_dist_list new_header got_article smtp_err)]
    ],
    heap => {
      nntpserver => $nntpserver,
      group   => $group,
      author  => $author,
      grades  => \@grades,
      smtp    => $smtp,
      mirror  => $mirror,
      checksum_path => $checksum_path,
    },
  );

  POE::Kernel->run;
  return;
}

#--------------------------------------------------------------------------#
# EVENT HANDLERS
#--------------------------------------------------------------------------#

sub _start {
  $_[KERNEL]->call( $_[SESSION], 'refresh_dist_list' );
  $_[KERNEL]->post( $group => 'register' );
  print "$0: startup completed; now monitoring for reports...\n";
  return;
}

# get $author CHECKSUMS file and put dist list in heap  
sub refresh_dist_list {
  my ($heap) = $_[HEAP];
  my $checksum_path = $heap->{checksum_path};
  my $mirror = $heap->{mirror};
  my $url = "${mirror}${checksum_path}";
  my $file = get($url);
  die "$0: error getting $url\n" unless defined $file;
  $file =~ s/\015?\012/\n/;
  my $safe = Safe->new;
  my $checksums = $safe->reval($file);
  if ( ref $checksums eq 'HASH' ) {
    # clear dist list
    $_[HEAP]->{dists} = {};
    for my $f ( keys %$checksums ) {
      # use the .meta key so we don't worry about tarball suffixes
      next unless $f =~ /.meta$/;
      $f =~ s/.meta$//;
      $_[HEAP]->{dists}{$f} = 1;
    }
  }
  else {
    die "$0: Couldn't get distributions by $heap->{author} from $mirror\n";
  }
  # refresh in 12 hours
  $_[KERNEL]->delay( 'refresh_dist_list' => 3600 * 12 );
  return;
}

sub new_header {
  my ($kernel, $heap, $article_id, $lines) = @_[KERNEL, HEAP, ARG0, ARG1];
  my $article = Email::Simple->new( join "\015\012", @$lines );
  my $subject = $article->header('Subject');
  my ($grade, $dist) = split " ", $subject;
  if ( $heap->{dists}{$dist} && grep { $grade eq $_ } @{$heap->{grades}} ) {
    $kernel->post( $group => 'get_article' => $article_id );
  }
  return;
}

sub got_article {
  my ($kernel, $heap, $article_id, $lines) = @_[KERNEL, HEAP, ARG0, ARG1];
  my $article = Email::Simple->new( join "\015\012", @$lines );
  my $subject = $article->header('Subject');
  my ($from) = Email::Address->parse( $article->header('From') ) 
    or die "$0: parse error '" . $article->header('From') . "'\n";
  my $sender = $from->address;
  
  print "$0: from $sender\: $subject\n";
  POE::Component::Client::SMTP->send(
    From          => $sender,
    To            => "$heap->{author}\@cpan.org",
    Body          => $article->as_string,
    Server        => $heap->{smtp},
    Context       => $article_id,
    SMTP_Failure  => 'smtp_err',
  );

  return;
}

my %failed;
sub smtp_err {
  my ($article_id, $errors) = @_[ARG0, ARG1];
  if ( $errors->{SMTP_Server_Error} ) {
    warn "$0: SMTP error sending report $article_id\: $errors->{SMTP_Server_Error}\n";
  }
  elsif ( $errors->{Timeout} ) {
    warn "$0: Timeout sending report $article_id\n";
  }
  elsif ( $errors->{Configure} ) {
    warn "$0: Could not authenticate to SMTP server\n";
  }
  elsif ( $errors->{'POE::Wheel::SocketFactory'} ) {
    my ($operation, $errnum, $errstr) = @{ $errors->{'POE::Wheel::SocketFactory'} };
    warn "$0: Error during '$operation' for $article_id\: $errstr\n";
  }
  else {
    warn "$0: Internal error sending report $article_id\n"
  }
  if ( ! $failed{$article_id}++ ) {
    warn "$0: will try again to send report $article_id\n";
    $_[KERNEL]->post( $group => 'get_article' => $article_id );
  }
  else {
    warn "$0: will not try again for report $article_id\n";
  }
  return;
}

1;

__END__

=begin wikidoc

= NAME

App::CPAN::Testers::Remailer - monitor CPAN Testers and remail reports to an author

= VERSION

This documentation describes version %%VERSION%%.

= SYNOPSIS

    use App::CPAN::Testers::Remailer;
    App::CPAN::Testers::Remailer->run;

= DESCRIPTION

Internals for [cpantest-remailer] program.  See that for details.

= BUGS

Please report any bugs or feature using the CPAN Request Tracker.  
Bugs can be submitted through the web interface at 
[http://rt.cpan.org/Dist/Display.html?Queue=App-CPAN-Testers-Remailer]

When submitting a bug or request, please include a test-file or a patch to an
existing test-file that illustrates the bug or desired feature.

= SEE ALSO

* [cpantest-remailer]

= AUTHOR

David A. Golden (DAGOLDEN)

= COPYRIGHT AND LICENSE

Copyright (c) 2008 by David A. Golden. All rights reserved.

Licensed under Apache License, Version 2.0 (the "License").
You may not use this file except in compliance with the License.
A copy of the License was distributed with this file or you may obtain a 
copy of the License from http://www.apache.org/licenses/LICENSE-2.0

Files produced as output though the use of this software, shall not be
considered Derivative Works, but shall be considered the original work of the
Licensor.

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=end wikidoc

=cut

