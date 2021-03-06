# Copyright (c) 2008 by David Golden. All rights reserved.
# Licensed under Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License was distributed with this file or you may obtain a 
# copy of the License from http://www.apache.org/licenses/LICENSE-2.0

use 5.006;
use strict;
use warnings;
use lib 'inc';
eval "require Pod::WikiDoc";
my $class = $@ ? "Module::Build" : "Module::Build::DAGOLDEN";
eval "require $class";
my $build = $class->new( 
    module_name => 'App::CPAN::Testers::Remailer',
    dist_author => 'David Golden <dagolden@cpan.org>',
    license => 'apache',
    create_readme => 1,
    create_makefile_pl  => 'traditional',
    requires => {
        'perl' => '5.006',
        'Email::Address' => 1.888,
        'Email::Simple' => 2.003,
        'Getopt::Long' => 2.37, 
        'LWP::Simple' => 1.41,
        'Net::DNS' => 0.63,
        'POE::Component::Client::NNTP::Tail' => 0.01,
        'POE::Component::Client::SMTP' => 0.20,
        'Safe' => 2.10, 
    },
    build_requires => {
        'Test::More' => 0.47,
    },
    meta_add            => { 
        no_index => { 
            directory => [ qw/ examples inc t /],
        } 
    },
);
$build->create_build_script;

