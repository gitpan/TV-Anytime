package TV::Anytime;
use strict;
use warnings;
use DateTime;
use DateTime::Format::W3CDTF;
use DateTime::Format::Duration;
use File::Find::Rule;
use List::Util;
use Path::Class;
use TV::Anytime::Event;
use TV::Anytime::Genre;
use TV::Anytime::Program;
use TV::Anytime::Service;
use XML::LibXML;
use XML::LibXML::XPathContext;
use base 'Class::Accessor::Chained::Fast';
__PACKAGE__->mk_accessors(qw(directory));
our $VERSION = '0.29';

sub new {
  my $class     = shift;
  my $directory = shift;
  die "$directory not a directory" unless -d $directory;

  die "$directory does not contain ServiceInformation.xml"
    unless -f file($directory, "ServiceInformation.xml");

  my $self = {};
  bless $self, $class;
  $self->directory($directory);
  return $self;
}

sub _find_files {
  my ($self, $id, $type) = @_;
  my @files =
    File::Find::Rule->file->name("*${id}_${type}.xml")->in($self->directory);
  return @files;
}

sub _programs {
  my ($self, $id) = @_;
  my @programs = $self->_program_information($id);
  my @events   = $self->_program_location($id);

  my %programs;
  $programs{ $_->id } = $_ foreach @programs;

  my %events;
  foreach my $event (@events) {
    $event->program($programs{ $event->crid });
    push @{ $events{ $event->crid } }, $event;
  }

  foreach my $program (@programs) {
    $program->events_ref($events{ $program->id });
  }

  return \@programs, \@events;
}

sub _program_information {
  my ($self, $id) = @_;
  my @programs;
  foreach my $file ($self->_find_files($id, "pi")) {
    push @programs, $self->_program_information_single($id, $file);
  }
  return @programs;
}

sub _program_information_single {
  my ($self, $id, $filename) = @_;
  my $xpc = $self->_parse_file($filename);
  my @programs;
  foreach my $node ($xpc->findnodes("//tva:ProgramInformation")) {
    my $program = TV::Anytime::Program->new;
    $program->id($node->getAttribute('programId'));
    $program->title($xpc->findvalue(".//tva:Title",       $node));
    $program->synopsis($xpc->findvalue(".//tva:Synopsis", $node));
    $program->caption_language(
      $xpc->findvalue(".//tva:CaptionLanguage", $node));
    $program->audio_channels($xpc->findvalue(".//tva:NumOfChannels", $node));
    $program->aspect_ratio($xpc->findvalue(".//tva:AspectRatio",     $node));

    my @member_of;
    foreach my $subnode ($self->_xpc($node)->findnodes(".//tva:MemberOf")) {
      push @member_of, $subnode->getAttribute('crid');
    }
    $program->member_of(\@member_of);

    my @genres;
    foreach my $subnode ($self->_xpc($node)->findnodes(".//tva:Genre")) {
      my $href  = $subnode->getAttribute('href');
      $href =~ s/^urn:tva:metadata:cs:(.+?):.+$/$1/;
      push @genres, TV::Anytime::Genre->new({
        name  => $href,
        value => $self->_xpc($subnode)->findvalue("./tva:Name"),
      });
    }
    $program->genres_ref(\@genres);

    push @programs, $program;
  }
  return @programs;
}

sub _program_location {
  my ($self, $id) = @_;

  my @events;
  foreach my $file ($self->_find_files($id, "pl")) {
    push @events, $self->_program_location_single($id, $file);
  }
  return @events;
}

sub _program_location_single {
  my ($self, $id, $filename) = @_;
  my $xpc = $self->_parse_file($filename);
  my @events;
  foreach my $node ($xpc->findnodes("//tva:ScheduleEvent")) {
    my $nodexpc = $self->_xpc($node);
    my $event   = TV::Anytime::Event->new;
    $event->crid($nodexpc->findnodes("./tva:Program", $node)->get_node(0)
        ->getAttribute('crid'));
    $event->start(
      $self->_parse_date($nodexpc->findvalue('./tva:PublishedStartTime')));
    my $duration =
      $self->_parse_duration($nodexpc->findvalue('./tva:PublishedDuration'));
    $event->stop($event->start + $duration);
    push @events, $event;
  }
  return @events;
}

sub services {
  my $self = shift;
  my @services;
  my $xpc = $self->_parse_file("ServiceInformation.xml");
  foreach my $node ($xpc->findnodes("//tva:ServiceInformation")) {

    my @genres;
    foreach my $subnode ($self->_xpc($node)->findnodes("./tva:ServiceGenre")) {
      my $href = $subnode->getAttribute('href');
      $href =~ s/^urn:tva:metadata:cs:(.+?):.+$/$1/;
      push @genres,
        TV::Anytime::Genre->new(
        {
          name  => $href,
          value => $self->_xpc($subnode)->findvalue("./tva:Name"),
        }
        );
    }
    push @services,
      TV::Anytime::Service->new(
      {
        anytime    => $self,
        id         => $node->getAttribute('serviceId'),
        name       => $xpc->findvalue("./tva:Name", $node),
        owner      => $xpc->findvalue("./tva:Owner", $node),
        logo       => $xpc->findvalue("./tva:Logo", $node),
        genres_ref => \@genres,
      }
      );
  }
  return @services;
}

sub services_television {
  my $self = shift;
  return grep { $_->is_television } $self->services;
}

sub services_radio {
  my $self = shift;
  return grep { $_->is_radio } $self->services;
}

sub _parse_file {
  my ($self, $filename) = @_;
  my $directory = $self->directory;
  my $path      = $filename;
  $path = dir($self->directory, $filename) unless $filename =~ /$directory/;
  my $parser = XML::LibXML->new;
  my $doc    = $parser->parse_file($path);
  return $self->_xpc($doc);
}

sub _xpc {
  my ($self, $node) = @_;
  my $xpc = XML::LibXML::XPathContext->new($node);
  $xpc->registerNs('tva', 'urn:tva:metadata:2002');
  $xpc->registerNs('rss', 'http://purl.org/rss/1.0/');
  return $xpc;
}

sub _parse_date {
  my ($self, $string) = @_;
  my $f = DateTime::Format::W3CDTF->new;
  return $f->parse_datetime($string);
}

sub _parse_duration {
  my ($self, $string) = @_;
  my $d = DateTime::Format::Duration->new(pattern => 'PT%HH%MM%SS',);
  return $d->parse_duration($string);
}

1;

__END__

=head1 NAME

TV::Anytime - Parse TV-AnyTime bundles of TV and Radio listings

=head1 SYNOPSIS

  use TV::Anytime;
  my $tv = TV::Anytime->new("data/20050701/");

  # Find out what services are available
  my @services = $tv->services;
  my @radio_services = $tv->services_radio;
  my @tv_services = $tv->services_television;

=head1 DESCRIPTION

The L<TV::Anytime> module parses TV-Anytime bundles. TV-Anytime is a format organised
by the TV-Anytime Forum (L<http://www.tv-anytime.org/>). These are open
standards (see ETSI TS102822) for the rich description of Radio,
Television and other types of media. The metadata specification includes
a comprehensive genre scheme, methods of linking and grouping
programmes, listing credits and lots of other data fields.

This module is concerned with parsing TV-Anytime files that are shipped
by the British Broadcasting Corporation from
L<http://backstage.bbc.co.uk/feeds/tvradio/doc.html>. It is assumed that
you have downloaded a .tar.gz from this site and have unpacked it.

=head1 METHODS

=head2 new()

The new() method is the constructor. It takes the directory into which
you have unpacked the TV-Anytime files:

  my $tv = TV::Anytime->new("data/20050701/");

=head2 services

The services() method returns a list of all the available services as a
list of L<TV::Anytime::Service> objects:

  my @services = $tv->services;
  
=head2 services_radio

The services_radio() method returns a list of the available radio
services as a list of L<TV::Anytime::Service> objects:

  my @radio_services = $tv->services_radio;

=head2 services_television

The serviices_television() method returns a list of all the available
television services as a list of L<TV::Anytime::Service> objects:

  my @tv_services = $tv->services_television;

=head1 SEE ALSO 

L<TV::Anytime::Service>

=head1 BUGS                                                   
                                                                                
Please report any bugs or feature requests to                                   
C<bug-TV-Anytime@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.  

=head1 AUTHOR

Leon Brocard C<acme@astray.com>

=head1 LICENCE AND COPYRIGHT                                                    
                                                                                
Copyright (c) 2005, Leon Brocard C<acme@astray.com>. All rights reserved.
                                                                                
This module is free software; you can redistribute it and/or                    
modify it under the same terms as Perl itself.                                  
                                                
