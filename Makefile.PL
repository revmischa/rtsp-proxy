use 5.010000;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'RTSP::Proxy',
    VERSION_FROM      => 'lib/RTSP/Proxy.pm', # finds $VERSION
    PREREQ_PM         => {
        'RTSP::Client' => '0.03',
        'Net::Server::PreFork' => undef,
        'Moose' => undef,
    },
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/RTSP/Proxy.pm', # retrieve abstract from module
       AUTHOR         => 'Mischa Spiegelmock <revmischa@cpan.org>') : ()),
);