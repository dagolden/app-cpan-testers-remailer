package Module::Build::DAGOLDEN;
use strict;
use base qw/Module::Build/;
use IO::File;
use File::Spec;

sub ACTION_distmeta {
    my $self = shift;
    $self->depends_on('templates');
    $self->depends_on('wikidoc');
    $self->SUPER::ACTION_distmeta;
}

sub ACTION_testpod {
    my $self = shift;
    $self->depends_on('wikidoc');
    $self->SUPER::ACTION_testpod;
}

sub ACTION_test {
    my $self = shift;
    my $missing_pod;
    for my $src ( keys %{ $self->find_pm_files() } ) {
        next unless _has_pod($src);
        (my $tgt = $src) =~ s{\.pm$}{.pod};
        $missing_pod = 1 if ! -e $tgt;
    }
    if ( $missing_pod ) {
        $self->depends_on('wikidoc');
        $self->depends_on('build');
    }
    $self->SUPER::ACTION_test;
}

sub ACTION_wikidoc {
    my $self = shift;
    eval "use Pod::WikiDoc";
    if ( $@ eq '' ) {
        my $parser = Pod::WikiDoc->new({ 
            comment_blocks => 1,
            keywords => { VERSION => $self->dist_version },
        });
        for my $src ( keys %{ $self->find_pm_files() } ) {
            next unless _has_pod( $src ); 
            (my $tgt = $src) =~ s{\.pm$}{.pod};
            $parser->filter( {
                input   => $src,
                output  => $tgt,
            });
            print "Creating $tgt\n";
            $tgt =~ s{\\}{/}g;
            $self->_add_to_manifest( 'MANIFEST', $tgt );
        }
        for my $src ( keys %{ $self->find_script_files() } ) {
            next unless _has_pod( $src ); 
            my $script = IO::File->new($src, "r+");
            my $mark = tell $script;
            my $text = q{};
            while (my $line = <$script>) {
                last if $line =~ m{Generated by Pod::WikiDoc}i;
                $text .= $line;
                $mark = tell $script;
            }
            truncate $script, $mark;
            seek $script, 0, 2; # EOF
            my $pod = $parser->convert( $text );
            print "Updating Pod in $src\n";
            print {$script} $pod;
        }
    }
    else {
        warn "Pod::WikiDoc not available. Skipping wikidoc.\n";
    }
}

sub _has_pod {
    my ($file) = shift;
    warn "Scanning $file...\n";
    my $fh = IO::File->new( $file );
    my $data = do {local $/; <$fh>};
    return $data =~ m{^=(?:pod|head\d|over|item|begin)\b}ms;
}

#--------------------------------------------------------------------------#

sub ACTION_templates {
    my $self = shift;
    my $share_dir = "share";
    my $module = "Module::Boilerplate::Templates";
    my $version = $self->dist_version;
    my $out_file = "lib/$module\.pm";
    $out_file =~ s{::}{/}g;
    eval "use File::Find qw/find/; use File::Slurp qw/read_file/";
    if ( $@ || ! -d $share_dir ) {
        warn "Skipping template construction.";
        return;
    }

    print "Creating $out_file\n";

    open my $fh, ">", $out_file or die "$!";

    print {$fh} "package $module;\nuse 5.006;\nuse strict;\nuse warnings;\n";
    print {$fh} "\nour \$VERSION = '$version';\n\$VERSION = eval \$VERSION;\n";
    print {$fh} << 'HERE';

my $DATA_start_pos = tell DATA;

my %index;
my $line_count = 0;
while (my $line = <DATA>) {
    $line_count++;
    if ( $line =~ m{\A____\s(.+?)\s____} ) {
        my $filename = $1;    
        my $start = $line_count; # header
        SKIP: while ( <DATA> ) { 
            $line_count++; 
            last SKIP if m{\A\s*\n\z}; 
        }
        my $length = $line_count - $start - 1;
        $index{$filename} = [$start, $length];
    }
}

sub files {
    return keys %index;
}

sub file {
    my ($self, $f) = @_;
    my ($start, $length) = @{ $index{$f} };
    seek DATA, $DATA_start_pos, 0;
    <DATA> for (1 .. $start);
    my $uu;
    $uu .= <DATA> for (1 .. $length);
    return unpack("u*", $uu);
}

1;
__DATA__
HERE

    find( 
        sub {
            return unless -f;
            (my $f = $File::Find::name) =~ s{^[^/]+?/}{};
            $f =~ s{$share_dir/}{}g;
            print {$fh} "____ $f ____\n";
            print {$fh} pack("u*",scalar read_file($_)), "\n";
        },
        $share_dir 
    );

    close $fh;

}

1;
