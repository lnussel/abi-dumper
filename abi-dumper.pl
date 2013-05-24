#!/usr/bin/perl
###########################################################################
# ABI Dumper 0.95
# Dump ABI of an ELF object containing DWARF debug info
#
# Copyright (C) 2013 ROSA Laboratory
#
# Written by Andrey Ponomarenko
#
# PLATFORMS
# =========
#  Linux, FreeBSD
#
# REQUIREMENTS
# ============
#  Elfutils (eu-readelf)
#  Perl 5 (5.8 or newer)
#  Vtable-Dumper (1.0 or newer)
#
# COMPATIBILITY
# =============
#  ABI Compliance Checker >= 1.99
#
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License or the GNU Lesser
# General Public License as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# and the GNU Lesser General Public License along with this program.
# If not, see <http://www.gnu.org/licenses/>.
###########################################################################
use Getopt::Long;
Getopt::Long::Configure ("posix_default", "no_ignore_case", "permute");
use File::Path qw(mkpath rmtree);
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd realpath);
use Data::Dumper;

my $TOOL_VERSION = "0.95";
my $ABI_DUMP_VERSION = "3.0";
my $ORIG_DIR = cwd();
my $TMP_DIR = tempdir(CLEANUP=>1);

my $VTABLE_DUMPER = "vtable-dumper";
my $VTABLE_DUMPER_VERSION = "1.0";

my ($Help, $ShowVersion, $DumpVersion, $OutputDump, $SortDump, $StdOut,
$TargetVersion, $ExtraInfo, $FullDump, $AllTypes, $AllSymbols, $BinOnly,
$SkipCxx, $Loud);

my $CmdName = get_filename($0);

my %ERROR_CODE = (
    "Success"=>0,
    "Error"=>2,
    # System command is not found
    "Not_Found"=>3,
    # Cannot access input files
    "Access_Error"=>4,
    # Cannot find a module
    "Module_Error"=>9
);

my $ShortUsage = "ABI Dumper $TOOL_VERSION
Dump ABI of an ELF object containing DWARF debug info
Copyright (C) 2013 ROSA Laboratory
License: GNU LGPL or GNU GPL

Usage: $CmdName [options] [object]
Example:
  $CmdName libTest.so -o ABI.dump
  $CmdName Module.ko.debug -o ABI.dump

More info: $CmdName --help\n";

if($#ARGV==-1)
{
    printMsg("INFO", $ShortUsage);
    exit(0);
}

GetOptions("h|help!" => \$Help,
  "v|version!" => \$ShowVersion,
  "dumpversion!" => \$DumpVersion,
# general options
  "o|output|dump-path=s" => \$OutputDump,
  "sort!" => \$SortDump,
  "stdout!" => \$StdOut,
  "loud!" => \$Loud,
  "lver|lv=s" => \$TargetVersion,
  "extra-info=s" => \$ExtraInfo,
  "all-types!" => \$AllTypes,
  "all-symbols!" => \$AllSymbols,
  "skip-cxx!" => \$SkipCxx,
  "all!" => \$FullDump,
  "bin-only!" => \$BinOnly
) or ERR_MESSAGE();

sub ERR_MESSAGE()
{
    printMsg("INFO", "\n".$ShortUsage);
    exit($ERROR_CODE{"Error"});
}

my $HelpMessage="
NAME:
  ABI Dumper ($CmdName)
  Dump ABI of an ELF object containing DWARF debug info

DESCRIPTION:
  ABI Dumper is a tool for dumping ABI information of an ELF object
  containing DWARF debug info.
  
  The tool is intended to be used with ABI Compliance Checker tool for tracking
  ABI changes of a C/C++ library or kernel module.

  This tool is free software: you can redistribute it and/or modify it
  under the terms of the GNU LGPL or GNU GPL.

USAGE:
  $CmdName [options] [object]

EXAMPLES:
  $CmdName libTest.so -o ABI.dump
  $CmdName Module.ko.debug -o ABI.dump

INFORMATION OPTIONS:
  -h|-help
      Print this help.

  -v|-version
      Print version information.

  -dumpversion
      Print the tool version ($TOOL_VERSION) and don't do anything else.

GENERAL OPTIONS:
  -o|-output PATH
      Path to the output ABI dump file.
      Default: ./ABI.dump
      
  -sort
      Sort data in ABI dump.
      
  -stdout
      Print ABI dump to stdout.
      
  -loud
      Print all warnings.
      
  -lv|-lver NUM
      Set version of the library to NUM.
      
  -extra-info DIR
      Dump extra analysis info to DIR.
      
  -bin-only
      Do not dump information about inline functions,
      pure virtual functions and non-exported global data.
      
  -all-types
      Dump unused data types.
      
  -all-symbols
      Dump symbols not exported by the object.
      
  -skip-cxx
      Do not dump stdc++ and gnu c++ symbols.
      
  -all
      Equal to: -all-types -all-symbols
";

sub HELP_MESSAGE() {
    printMsg("INFO", $HelpMessage);
}

my %Cache;

# Input
my %DWARF_Info;
my %DWARF_Info_Kind;
my %DWARF_Info_NS;
my %DWARF_Info_ID;

# Output
my %SymbolInfo;
my %TypeInfo;

# Reader
my %TypeMember;
my %ArrayCount;
my %FuncParam;
my %Inheritance;
my %NameSpace;
my %SpecElem;
my %ClassMethods;
my %TypeSpec;
my %ClassChild;

my %MergedTypes;
my %LocalType;

my %SourceFile;
my %DebugLoc;
my %CompUnit;
my %TName_Tid;
my %RegName;

my $STDCXX_TARGET = 0;

my %Mangled_ID;
my %Checked_Spec;
my %SelectedSymbols;

my %TypeType = (
    "class_type"=>"Class",
    "structure_type"=>"Struct",
    "union_type"=>"Union",
    "enumeration_type"=>"Enum",
    "array_type"=>"Array",
    "base_type"=>"Intrinsic",
    "const_type"=>"Const",
    "pointer_type"=>"Pointer",
    "reference_type"=>"Ref",
    "volatile_type"=>"Volatile",
    "typedef"=>"Typedef",
    "ptr_to_member_type"=>"FieldPtr"
);

my %Qual = (
    "Pointer"=>"*",
    "Ref"=>"&",
    "Volatile"=>"volatile",
    "Const"=>"const"
);

my $HEADER_EXT = "h|hh|hp|hxx|hpp|h\\+\\+";
my $SRC_EXT = "c|cpp|cxx|c\\+\\+";

# Other
my %NestedNameSpaces;
my $TargetName;
my %SysInfo;
my %HeadersInfo;
my %SourcesInfo;
my %SymVer;
my %UsedType;

# ELF
my %Library_Symbol;
my %Library_UndefSymbol;
my %Library_Needed;

# VTables
my %VirtualTable;

# Env
my $SYS_ARCH;
my $SYS_WORD;
my $SYS_GCCV;
my $SYS_COMP;

my $LIB_LANG;

sub printMsg($$)
{
    my ($Type, $Msg) = @_;
    if($Type!~/\AINFO/) {
        $Msg = $Type.": ".$Msg;
    }
    if($Type!~/_C\Z/) {
        $Msg .= "\n";
    }
    if($Type eq "ERROR") {
        print STDERR $Msg;
    }
    else {
        print $Msg;
    }
}

sub exitStatus($$)
{
    my ($Code, $Msg) = @_;
    printMsg("ERROR", $Msg);
    exit($ERROR_CODE{$Code});
}

sub cmpVersions($$)
{ # compare two versions in dotted-numeric format
    my ($V1, $V2) = @_;
    return 0 if($V1 eq $V2);
    return undef if($V1!~/\A\d+[\.\d+]*\Z/);
    return undef if($V2!~/\A\d+[\.\d+]*\Z/);
    my @V1Parts = split(/\./, $V1);
    my @V2Parts = split(/\./, $V2);
    for (my $i = 0; $i <= $#V1Parts && $i <= $#V2Parts; $i++) {
        return -1 if(int($V1Parts[$i]) < int($V2Parts[$i]));
        return 1 if(int($V1Parts[$i]) > int($V2Parts[$i]));
    }
    return -1 if($#V1Parts < $#V2Parts);
    return 1 if($#V1Parts > $#V2Parts);
    return 0;
}

sub writeFile($$)
{
    my ($Path, $Content) = @_;
    return if(not $Path);
    if(my $Dir = get_dirname($Path)) {
        mkpath($Dir);
    }
    open(FILE, ">", $Path) || die ("can't open file \'$Path\': $!\n");
    print FILE $Content;
    close(FILE);
}

sub readFile($)
{
    my $Path = $_[0];
    return "" if(not $Path or not -f $Path);
    open(FILE, $Path);
    local $/ = undef;
    my $Content = <FILE>;
    close(FILE);
    return $Content;
}

sub get_filename($)
{ # much faster than basename() from File::Basename module
    if($_[0] and $_[0]=~/([^\/\\]+)[\/\\]*\Z/) {
        return $1;
    }
    return "";
}

sub get_dirname($)
{ # much faster than dirname() from File::Basename module
    if($_[0] and $_[0]=~/\A(.*?)[\/\\]+[^\/\\]*[\/\\]*\Z/) {
        return $1;
    }
    return "";
}

sub check_Cmd($)
{
    my $Cmd = $_[0];
    return "" if(not $Cmd);
    if(defined $Cache{"check_Cmd"}{$Cmd}) {
        return $Cache{"check_Cmd"}{$Cmd};
    }
    foreach my $Path (sort {length($a)<=>length($b)} split(/:/, $ENV{"PATH"}))
    {
        if(-x $Path."/".$Cmd) {
            return ($Cache{"check_Cmd"}{$Cmd} = 1);
        }
    }
    return ($Cache{"check_Cmd"}{$Cmd} = 0);
}

my %ELF_BIND = map {$_=>1} (
    "WEAK",
    "GLOBAL"
);

my %ELF_TYPE = map {$_=>1} (
    "FUNC",
    "IFUNC",
    "OBJECT",
    "COMMON"
);

my %ELF_VIS = map {$_=>1} (
    "DEFAULT",
    "PROTECTED"
);

sub readline_ELF($)
{ # read the line of 'readelf' output corresponding to the symbol
    my @Info = split(/\s+/, $_[0]);
    #  Num:   Value      Size Type   Bind   Vis       Ndx  Name
    #  3629:  000b09c0   32   FUNC   GLOBAL DEFAULT   13   _ZNSt12__basic_fileIcED1Ev@@GLIBCXX_3.4
    #  135:   00000000    0   FUNC   GLOBAL DEFAULT   UNDEF  av_image_fill_pointers@LIBAVUTIL_52 (3)
    shift(@Info); # spaces
    shift(@Info); # num
    
    if($#Info==7)
    { # UNDEF SYMBOL (N)
        if($Info[7]=~/\(\d+\)/) {
            pop(@Info);
        }
    }
    
    if($#Info!=6)
    { # other lines
        return ();
    }
    return () if(not defined $ELF_TYPE{$Info[2]} and $Info[5] ne "UNDEF");
    return () if(not defined $ELF_BIND{$Info[3]});
    return () if(not defined $ELF_VIS{$Info[4]});
    if($Info[5] eq "ABS" and $Info[0]=~/\A0+\Z/)
    { # 1272: 00000000     0 OBJECT  GLOBAL DEFAULT  ABS CXXABI_1.3
        return ();
    }
    if(index($Info[2], "0x") == 0)
    { # size == 0x3d158
        $Info[2] = hex($Info[2]);
    }
    return @Info;
}

sub read_Symbols($)
{
    my $Lib_Path = $_[0];
    my $Lib_Name = get_filename($Lib_Path);
    
    my $Dynamic = ($Lib_Name=~/\.so(\.|\Z)/);
    my $Dbg = ($Lib_Name=~/\.debug\Z/);
    
    my $Readelf = "eu-readelf";
    if(not check_Cmd($Readelf)) {
        exitStatus("Not_Found", "can't find \"eu-readelf\"");
    }
    $Readelf .= " -hlSsdA \"$Lib_Path\" 2>\"$TMP_DIR/error\"";
    
    my $ExtraPath = "";
    
    if($ExtraInfo) {
        mkpath($ExtraInfo);
    }
    
    if($ExtraInfo) {
        $ExtraPath = $ExtraInfo."/elf-info";
    }
    
    if($ExtraPath)
    { # debug mode
        # write to file
        system($Readelf." >\"$ExtraPath\"");
        open(LIB, $ExtraPath);
    }
    else
    { # write to pipe
        open(LIB, $Readelf." |");
    }
    
    my (%Interface_Value, %Value_Interface) = ();
    
    my $symtab = undef; # indicates that we are processing 'symtab' section of 'readelf' output
    while(<LIB>)
    {
        if($Dynamic and not $Dbg)
        { # dynamic library specifics
            if(defined $symtab)
            {
                if(index($_, "'.dynsym'")!=-1)
                { # dynamic table
                    $symtab = undef;
                }
                # do nothing with symtab
                next;
            }
            elsif(index($_, "'.symtab'")!=-1)
            { # symbol table
                $symtab = 1;
                next;
            }
        }
        if(my ($Value, $Size, $Type, $Bind, $Vis, $Ndx, $Symbol) = readline_ELF($_))
        { # read ELF entry
            if(skipSymbol($Symbol)) {
                next;
            }
            
            if($Ndx eq "UNDEF")
            { # ignore interfaces that are imported from somewhere else
                $Library_UndefSymbol{$TargetName}{$Symbol} = 0;
                next;
            }
            
            $Library_Symbol{$TargetName}{$Symbol} = ($Type eq "OBJECT")?-$Size:1;
            
            $Interface_Value{$Symbol} = $Value;
            $Value_Interface{$Value}{$Symbol} = 1;
        }
        elsif($Dynamic)
        { # dynamic library specifics
            if(/NEEDED.+\[([^\[\]]+)\]/)
            { # dependencies:
              # 0x00000001 (NEEDED) Shared library: [libc.so.6]
                $Library_Needed{$1} = 1;
            }
        }
    }
    close(LIB);
    
    my %Found = ();
    foreach my $Symbol (keys(%{$Library_Symbol{$TargetName}}))
    {
        next if(index($Symbol,"\@")==-1);
        if(my $Value = $Interface_Value{$Symbol})
        {
            foreach my $Symbol_SameValue (keys(%{$Value_Interface{$Value}}))
            {
                if($Symbol_SameValue ne $Symbol
                and index($Symbol_SameValue,"\@")==-1)
                {
                    $SymVer{$Symbol_SameValue} = $Symbol;
                    $Found{$Symbol} = 1;
                    last;
                }
            }
        }
    }
    
    # default
    foreach my $Symbol (keys(%{$Library_Symbol{$TargetName}}))
    {
        next if(defined $Found{$Symbol});
        next if(index($Symbol,"\@\@")==-1);
        
        if($Symbol=~/\A([^\@]*)\@\@/
        and not $SymVer{$1})
        {
            $SymVer{$1} = $Symbol;
            $Found{$Symbol} = 1;
        }
    }
    
    # non-default
    foreach my $Symbol (keys(%{$Library_Symbol{$TargetName}}))
    {
        next if(defined $Found{$Symbol});
        next if(index($Symbol,"\@")==-1);
        
        if($Symbol=~/\A([^\@]*)\@([^\@]*)/
        and not $SymVer{$1})
        {
            $SymVer{$1} = $Symbol;
            $Found{$Symbol} = 1;
        }
    }
}

sub read_DWARF_Info($)
{
    my $Path = $_[0];
    
    my $Readelf = "eu-readelf";
    if(not check_Cmd($Readelf)) {
        exitStatus("Not_Found", "can't find \"$Readelf\" command");
    }
    
    my $ExtraPath = "";
    
    if($ExtraInfo) {
        mkpath($ExtraInfo);
    }
    
    # ELF header
    if($ExtraInfo) {
        $ExtraPath = $ExtraInfo."/elf-header";
    }
    
    if($ExtraPath)
    {
        system($Readelf." -h \"$Path\" 2>\"$TMP_DIR/error\" >\"$ExtraPath\"");
        open(HEADER, $ExtraPath);
    }
    else {
        open(HEADER, "$Readelf -h \"$Path\" 2>\"$TMP_DIR/error\" |");
    }
    
    my %Header = ();
    while(<HEADER>)
    {
        if(/\A\s*([\w ]+?)\:\s*(.+?)\Z/) {
            $Header{$1} = $2;
        }
    }
    close(HEADER);
    
    $SYS_ARCH = $Header{"Machine"};
    
    if($SYS_ARCH=~/80\d86/)
    { # i386, i586, etc.
        $SYS_ARCH = "x86";
    }
    
    # source info
    if($ExtraInfo) {
        $ExtraPath = $ExtraInfo."/debug_line";
    }
    
    if($ExtraPath)
    {
        system("$Readelf --debug-dump=line \"$Path\" 2>\"$TMP_DIR/error\" >\"$ExtraPath\"");
        open(SRC, $ExtraPath);
    }
    else {
        open(SRC, "$Readelf --debug-dump=line \"$Path\" 2>\"$TMP_DIR/error\" |");
    }
    
    if(my $Error = readFile("$TMP_DIR/error"))
    {
        if($Error=~/No DWARF/i) {
            return 0;
        }
    }
    
    
    my $Offset = undef;
    
    while(<SRC>)
    {
        if(/Table at offset (\w+)/)
        {
            $Offset = $1;
        }
        elsif(defined $Offset
        and /(\d+)\s+\d+\s+\d+\s+\d+\s+([^ ]+)/)
        {
            my ($Num, $File) = ($1, $2);
            chomp($File);
            
            $SourceFile{$Offset}{$Num} = $File;
            
            if($File=~/\.($HEADER_EXT)\Z/) {
                $HeadersInfo{$File} = 1;
            }
            elsif($File ne "<built-in>") {
                $SourcesInfo{$File} = 1;
            }
        }
    }
    close(SRC);
    
    # debug_loc
    if($ExtraInfo) {
        $ExtraPath = $ExtraInfo."/debug_loc";
    }
    
    if($ExtraPath)
    {
        system("$Readelf --debug-dump=loc \"$Path\" 2>\"$TMP_DIR/error\" >\"$ExtraPath\"");
        open(LOC, $ExtraPath);
    }
    else {
        open(LOC, "$Readelf --debug-dump=loc \"$Path\" 2>\"$TMP_DIR/error\" |");
    }
    
    while(<LOC>)
    {
        if(/\[\s*(\w+)\].*\[\s*\w+\]\s*(.+)\Z/) {
            $DebugLoc{$1} = $2;
        }
    }
    close(LOC);
    
    # dwarf
    if($ExtraInfo) {
        $ExtraPath = $ExtraInfo."/debug_info";
    }
    
    if($ExtraPath)
    {
        system("$Readelf --debug-dump=info \"$Path\" 2>\"$TMP_DIR/error\" >\"$ExtraPath\"");
        open(INFO, $ExtraPath);
    }
    else {
        open(INFO, "$Readelf --debug-dump=info \"$Path\" 2>\"$TMP_DIR/error\" |");
    }
    
    my $CUnit = undef;
    my $CUnit_F = undef;
    
    my $ID = undef;
    my $Kind = undef;
    my $NS = undef;
    
    while(<INFO>)
    {
        if($ID and /\A\s*(\w+)\s*(.+?)\s*\Z/)
        {
            my ($Attr, $Val) = ($1, $2);
            
            if($Val=~/\A\s*\(ref\d+\)\s*\[\s*(\w+)\]/)
            {
                $Val = hex($1);
            }
            elsif($Attr eq "name")
            {
                $Val=~s/\A\((strp|string)\)\s*\"(.*)\"\Z/$2/;
            }
            elsif(index($Attr, "_linkage_name")!=-1)
            {
                $Val=~s/\A\(strp\)\s*\"(.*)\"\Z/$1/;
                $Attr = "linkage_name";
            }
            elsif(index($Attr, "location")!=-1)
            {
                if($Val=~/ (-?\d+)\Z/) {
                    $Val = $1;
                }
                else
                {
                    if($Attr eq "location"
                    and $Kind eq "formal_parameter")
                    {
                        if($Val=~/location list\s+\[\s*(\w+)\]\Z/)
                        {
                            $Attr = "location_list";
                            $Val = $1;
                        }
                        elsif($Val=~/ reg(\d+)\Z/)
                        {
                            $Attr = "register";
                            $Val = $1;
                        }
                    }
                }
            }
            elsif($Attr eq "accessibility")
            {
                $Val=~s/\A\(.+?\)\s*//;
                $Val=~s/\s*\(.+?\)\Z//;
                if($Val eq "public") {
                    next;
                }
            }
            else
            {
                $Val=~s/\A\(\w+\)\s*(.*?)\Z/$1/;
            }
            
            $DWARF_Info{$ID}{$Attr} = "$Val";
            
            if($Kind eq "compile_unit")
            {
                if($Attr eq "stmt_list") {
                    $CUnit = $Val;
                }
                
                if(not defined $CUnit_F) {
                    $CUnit_F = $ID;
                }
            }
        }
        elsif(/\A\s{0,4}\[\s*(\w+)\](\s*)(\w+)/)
        {
            $ID = hex($1);
            $DWARF_Info_ID{$ID} = $1;
            
            $NS = $2;
            $Kind = $3;
            
            $DWARF_Info_NS{$ID} = length($NS);
            $DWARF_Info_Kind{$ID} = $Kind;
            
            $DWARF_Info{$ID}{"kind"} = $Kind;
            
            if(defined $CUnit) {
                $CompUnit{$ID} = $CUnit;
            }
            
            #$DWARF_Info{$ID}{"rid"} = $1;
            #$DWARF_Info{$ID}{"id"} = $ID;
        }
        elsif(not defined $SYS_WORD
        and /Address\s*size:\s*(\d+)/i)
        {
            $SYS_WORD = $1;
        }
    }
    close(INFO);
    
    if(defined $CUnit_F)
    {
        if(my $Compiler= $DWARF_Info{$CUnit_F}{"producer"})
        {
            $Compiler=~s/\A\"//;
            $Compiler=~s/\"\Z//;
            
            if($Compiler=~/GNU\s+(C|C\+\+)\s+(.+)\Z/)
            {
                $SYS_GCCV = $2;
                $SYS_GCCV=~s/\d+\s+\(.+\)\Z//; # 4.6.1 20110627 (Mandriva)
            }
            else {
                $SYS_COMP = $Compiler;
            }
        }
        if(my $Lang = $DWARF_Info{$CUnit_F}{"language"})
        {
            $Lang=~s/\s*\(.+?\)\Z//;
            if($Lang=~/C\d/i) {
                $LIB_LANG = "C";
            }
            elsif($Lang=~/C\+\+/i) {
                $LIB_LANG = "C++";
            }
            else {
                $LIB_LANG = $Lang;
            }
        }
    }
    
    return 1;
}

sub read_Vtables($)
{
    my $Path = $_[0];
    
    if(index($LIB_LANG, "C++")!=-1)
    {
        if(check_Cmd($VTABLE_DUMPER))
        {
            if(my $Version = `$VTABLE_DUMPER -dumpversion`)
            {
                if(cmpVersions($Version, $VTABLE_DUMPER_VERSION)<0)
                {
                    printMsg("ERROR", "the version of Vtable-Dumper should be $VTABLE_DUMPER_VERSION or newer");
                    return;
                }
            }
        }
        else
        {
            printMsg("ERROR", "cannot find \'$VTABLE_DUMPER\'");
            return;
        }
        
        my $Output = $TMP_DIR."/v-tables";
        
        if($ExtraInfo) {
            $Output = $ExtraInfo."/v-tables";
        }
        
        system("$VTABLE_DUMPER \"$Path\" 2>\"$TMP_DIR/error\" >\"$Output\"");
        
        my $Content = readFile($Output);
        foreach my $ClassInfo (split(/\n\n\n/, $Content))
        {
            if($ClassInfo=~/\AVtable\s+for\s+(.+)\n((.|\n)+)\Z/i)
            {
                my ($CName, $VTable) = ($1, $2);
                my @Entries = split(/\n/, $VTable);
                foreach (1 .. $#Entries)
                {
                    my $Entry = $Entries[$_];
                    if($Entry=~/\A(\d+)\s+(.+)\Z/) {
                        $VirtualTable{$CName}{$1} = $2;
                    }
                }
            }
        }
    }
}

sub dump_ABI()
{
    my %ABI = (
        "TypeInfo" => \%TypeInfo,
        "SymbolInfo" => \%SymbolInfo,
        "Symbols" => \%Library_Symbol,
        "UndefinedSymbols" => \%Library_UndefSymbol,
        "Needed" => \%Library_Needed,
        "SymbolVersion" => \%SymVer,
        "LibraryVersion" => $TargetVersion,
        "LibraryName" => $TargetName,
        "Language" => $LIB_LANG,
        "Headers" => \%HeadersInfo,
        "Sources" => \%SourcesInfo,
        "NameSpaces" => \%NestedNameSpaces,
        "Target" => "unix",
        "Arch" => $SYS_ARCH,
        "WordSize" => $SYS_WORD,
        "ABI_DUMP_VERSION" => $ABI_DUMP_VERSION,
        "ABI_DUMPER_VERSION" => $TOOL_VERSION,
    );
    
    if($SYS_GCCV) {
        $ABI{"GccVersion"} = $SYS_GCCV;
    }
    else {
        $ABI{"Compiler"} = $SYS_COMP;
    }
    
    my $ABI_DUMP = Dumper(\%ABI);
    
    if($StdOut)
    { # --stdout option
        print STDOUT $ABI_DUMP;
    }
    else
    {
        mkpath(get_dirname($OutputDump));
        
        open(DUMP, ">", $OutputDump) || die ("can't open file \'$OutputDump\': $!\n");
        print DUMP $ABI_DUMP;
        close(DUMP);
    }
}

sub read_ABI()
{
    my %CurID = ();
    my $Pos = 0;
    my $Inh = 0;
    
    foreach my $ID (sort {int($a) <=> int($b)} keys(%DWARF_Info))
    {
        $ID = "$ID";
        
        my $Kind = $DWARF_Info_Kind{$ID};
        
        my $NS = $DWARF_Info_NS{$ID};
        
        if($Kind=~/(struct|structure|class|union|enumeration|subroutine|array)_type/
        or $Kind eq "typedef"
        or $Kind eq "subprogram"
        or $Kind eq "inlined_subroutine"
        or $Kind eq "lexical_block"
        or $Kind eq "variable"
        or $Kind eq "namespace")
        {
            if($Kind ne "variable"
            and $Kind ne "typedef")
            {
                $Pos = 0;
                $Inh = 0;
                
                $CurID{$NS} = $ID;
            }
            
            if(my $CID = $CurID{$NS-2})
            {
                $NameSpace{$ID} = $CID;
                if($Kind eq "subprogram"
                or $Kind eq "variable")
                {
                    if($DWARF_Info_Kind{$CID}=~/class|struct/)
                    {
                        $ClassMethods{$CID}{$ID} = 1;
                        if(my $Sp = $DWARF_Info{$CID}{"specification"}) {
                            $ClassMethods{$Sp}{$ID} = 1;
                        }
                    }
                }
            }
            
            if(my $Spec = $DWARF_Info{$ID}{"specification"}) {
                $SpecElem{$Spec} = $ID;
            }
        }
        elsif($Kind eq "member")
        {
            my $CID = $CurID{$NS-2};
            if($CID) {
                $NameSpace{$ID} = $CID;
            }
            if($DWARF_Info_Kind{$CID}=~/class|struct/
            and not defined $DWARF_Info{$ID}{"data_member_location"})
            { # variable (global data)
                next;
            }
            $TypeMember{$CurID{$NS-2}}{$Pos} = $ID;
            $Pos += 1;
        }
        elsif($Kind eq "enumerator")
        {
            $TypeMember{$CurID{$NS-2}}{$Pos} = $ID;
            $Pos += 1;
        }
        elsif($Kind eq "inheritance")
        {
            my %In = (
                "id" => $DWARF_Info{$ID}{"type"},
                "access" => $DWARF_Info{$ID}{"accessibility"}
            );
            if(defined $DWARF_Info{$ID}{"virtuality"}) {
                $In{"virtual"} = 1;
            }
            $Inheritance{$CurID{$NS-2}}{$Inh} = \%In;
            $Inh += 1;
        }
        elsif($Kind eq "formal_parameter")
        {
            $FuncParam{$CurID{$NS-2}}{$Pos} = $ID;
            $Pos += 1;
        }
        elsif($Kind eq "unspecified_parameters")
        {
            $FuncParam{$CurID{$NS-2}}{$Pos} = $ID;
            $DWARF_Info{$ID}{"type"} = "-1"; # "..."
            $Pos += 1;
        }
        elsif($Kind eq "subrange_type")
        {
            if((my $Bound = $DWARF_Info{$ID}{"upper_bound"}) ne "") {
                $ArrayCount{$CurID{$NS-2}} = $Bound + 1;
            }
        }
    }
    
    # register "void" type
    %{$TypeInfo{"1"}} = (
        "Name"=>"void",
        "Type"=>"Intrinsic"
    );
    $TName_Tid{"void"} = "1";
    $Cache{"getTypeInfo"}{"1"} = 1;
    
    # register "..." type
    %{$TypeInfo{"-1"}} = (
        "Name"=>"...",
        "Type"=>"Intrinsic"
    );
    $TName_Tid{"..."} = "-1";
    $Cache{"getTypeInfo"}{"-1"} = 1;
    
    foreach my $ID (sort {int($a) <=> int($b)} keys(%DWARF_Info))
    {
        if(my $Kind = $DWARF_Info_Kind{$ID})
        {
            if(defined $TypeType{$Kind}) {
                getTypeInfo($ID);
            }
        }
    }
    
    foreach my $Tid (keys(%TypeInfo))
    {
        if(defined $TypeInfo{$Tid}
        and $TypeInfo{$Tid}{"Type"} eq "Typedef")
        {
            my $TN = $TypeInfo{$Tid}{"Name"};
            my $TL = $TypeInfo{$Tid}{"Line"};
            my $NS = $TypeInfo{$Tid}{"NameSpace"};
            
            if(my $BTid = $TypeInfo{$Tid}{"BaseType"})
            {
                if($TypeInfo{$BTid}{"Name"}=~/\Aanon\-(\w+)\-/)
                {
                    %{$TypeInfo{$Tid}} = %{$TypeInfo{$BTid}};
                    $TypeInfo{$Tid}{"Name"} = $1." ".$TN;
                    $TypeInfo{$Tid}{"Line"} = $TL;
                    
                    my $Name = $TypeInfo{$Tid}{"Name"};
                    
                    if(not defined $TName_Tid{$Name}
                    or $Tid<$TName_Tid{$Name}) {
                        $TName_Tid{$Name} = $Tid;
                    }
                    
                    if($NS) {
                        $TypeInfo{$Tid}{"NameSpace"} = $NS;
                    }
                    
                    delete($TName_Tid{$TypeInfo{$BTid}{"Name"}});
                    delete($TypeInfo{$BTid});
                }
            }
        }
    }
    
    foreach my $ID (sort {int($a) <=> int($b)} keys(%DWARF_Info))
    {
        if($DWARF_Info_Kind{$ID} eq "subprogram"
        or $DWARF_Info_Kind{$ID} eq "variable")
        {
            getSymbolInfo($ID);
        }
    }
    
    foreach my $ID (keys(%SymbolInfo))
    {
        if($LIB_LANG eq "C++")
        {
            if(not $SymbolInfo{$ID}{"MnglName"})
            {
                if($SymbolInfo{$ID}{"Artificial"}
                or index($SymbolInfo{$ID}{"ShortName"}, "~")==0)
                {
                    delete($SymbolInfo{$ID});
                    next;
                }
            }
        }
        
        if(not $SymbolInfo{$ID}{"Return"})
        { # void
            if(not $SymbolInfo{$ID}{"Constructor"}
            and not $SymbolInfo{$ID}{"Destructor"})
            {
                $SymbolInfo{$ID}{"Return"} = "1";
            }
        }
        
        if(defined $SymbolInfo{$ID}{"Source"})
        {
            if(not defined $SymbolInfo{$ID}{"Header"}) {
                $SymbolInfo{$ID}{"Line"} = $SymbolInfo{$ID}{"SourceLine"};
            }
            delete($SymbolInfo{$ID}{"SourceLine"});
        }
        
        my $S = selectSymbol($ID);
        
        if($S==0)
        {
            delete($SymbolInfo{$ID});
            next;
        }
        $SelectedSymbols{$ID} = $S;
        
        delete($SymbolInfo{$ID}{"External"});
    }
}

sub selectSymbol($)
{
    my $ID = $_[0];
    
    my $MnglName = $SymbolInfo{$ID}{"MnglName"};
    
    if(not $MnglName) {
        $MnglName = $SymbolInfo{$ID}{"ShortName"};
    }
    
    my $Exp = 0;
    
    if($Library_Symbol{$TargetName}{$MnglName}
    or $Library_Symbol{$TargetName}{$SymVer{$MnglName}})
    {
        $Exp = 1;
    }
    
    if(my $Alias = $SymbolInfo{$ID}{"Alias"})
    {
        if($Library_Symbol{$TargetName}{$Alias}
        or $Library_Symbol{$TargetName}{$SymVer{$Alias}})
        {
            $Exp = 1;
        }
    }
    
    if(not $Exp)
    {
        if(defined $Library_UndefSymbol{$TargetName}{$MnglName}
        or defined $Library_UndefSymbol{$TargetName}{$SymVer{$MnglName}})
        {
            return 0;
        }
        if($SymbolInfo{$ID}{"Data"}
        or $SymbolInfo{$ID}{"InLine"}
        or $SymbolInfo{$ID}{"PureVirt"})
        {
            if(defined $BinOnly)
            { # data, inline, pure
                return 0;
            }
            elsif(not defined $SymbolInfo{$ID}{"Header"})
            { # defined in source files
                return 0;
            }
            else {
                return 2;
            }
        }
        else
        {
            if(defined $AllSymbols)
            {
                if(not $SymbolInfo{$ID}{"External"})
                { # static symbols
                    return 0;
                }
            }
            else {
                return 0;
            }
        }
    }
    
    return 1;
}

sub formatName($$)
{ # type name correction
    if(defined $Cache{"formatName"}{$_[1]}{$_[0]}) {
        return $Cache{"formatName"}{$_[1]}{$_[0]};
    }
    
    my $N = $_[0];
    
    if($_[1] ne "S")
    {
        $N=~s/\A[ ]+//g;
        $N=~s/[ ]+\Z//g;
        $N=~s/[ ]{2,}/ /g;
    }
    
    $N=~s/[ ]*(\W)[ ]*/$1/g; # std::basic_string<char> const
    
    $N=~s/\b(const|volatile) ([\w\:]+)([\*&,>]|\Z)/$2 $1$3/g; # "const void" to "void const"
    
    $N=~s/\bvolatile const\b/const volatile/g;
    
    $N=~s/\b(long long|short|long) unsigned\b/unsigned $1/g;
    $N=~s/\b(short|long) int\b/$1/g;
    
    $N=~s/([\)\]])(const|volatile)\b/$1 $2/g;
    
    while($N=~s/>>/> >/g) {};
    
    if($_[1] eq "S")
    {
        if(index($N, "operator")!=-1) {
            $N=~s/\b(operator[ ]*)> >/$1>>/;
        }
    }
    
    $N=~s/,/, /g;
    
    return ($Cache{"formatName"}{$_[1]}{$_[0]} = $N);
}

sub separate_Params($)
{
    my $Str = $_[0];
    my @Parts = ();
    my %B = ( "("=>0, "<"=>0, ")"=>0, ">"=>0 );
    my $Part = 0;
    foreach my $Pos (0 .. length($Str) - 1)
    {
        my $S = substr($Str, $Pos, 1);
        if(defined $B{$S}) {
            $B{$S} += 1;
        }
        if($S eq "," and
        $B{"("}==$B{")"} and $B{"<"}==$B{">"}) {
            $Part += 1;
        }
        else {
            $Parts[$Part] .= $S;
        }
    }
    # remove spaces
    foreach (@Parts)
    {
        s/\A //g;
        s/ \Z//g;
    }
    return @Parts;
}

sub init_FuncType($$$)
{
    my ($TInfo, $FTid, $Type) = @_;
    
    $TInfo->{"Type"} = $Type;
    
    if($TInfo->{"Return"} = $DWARF_Info{$FTid}{"type"}) {
        getTypeInfo($TInfo->{"Return"});
    }
    else
    { # void
        $TInfo->{"Return"} = "1";
    }
    delete($TInfo->{"BaseType"});
    
    my @Prms = ();
    my $PPos = 0;
    foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$FuncParam{$FTid}}))
    {
        my $ParamId = $FuncParam{$FTid}{$Pos};
        my %PInfo = %{$DWARF_Info{$ParamId}};
        
        if(defined $PInfo{"artificial"})
        { # this
            next;
        }
        
        $TInfo->{"Param"}{$PPos}{"type"} = $PInfo{"type"};
        getTypeInfo($PInfo{"type"});
        push(@Prms, $TypeInfo{$PInfo{"type"}}{"Name"});
        
        $PPos += 1;
    }
    
    $TInfo->{"Name"} = $TypeInfo{$TInfo->{"Return"}}{"Name"};
    if($Type eq "FuncPtr") {
        $TInfo->{"Name"} .= "(*)";
    }
    else {
        $TInfo->{"Name"} .= "()";
    }
    $TInfo->{"Name"} .= "(".join(",", @Prms).")";
}

sub get_TParams($)
{
    my $Name = $_[0];
    if(my $Cent = find_center($Name, "<"))
    {
        my $TParams = substr($Name, $Cent);
        $TParams=~s/\A<|>\Z//g;
        
        $TParams = simpleName($TParams);
        
        my $Short = substr($Name, 0, $Cent);
        
        my @Params = separate_Params($TParams);
        foreach my $Pos (0 .. $#Params)
        {
            my $Param = $Params[$Pos];
            if($Param=~/\A(.+>)(.*?)\Z/)
            {
                my ($Tm, $Suf) = ($1, $2);
                my ($Sh, @Prm) = get_TParams($Tm);
                $Param = $Sh."<".join(", ", @Prm).">".$Suf;
            }
            $Params[$Pos] = formatName($Param, "T");
        }
        
        # default arguments
        if($Short eq "std::vector")
        {
            if($#Params==1)
            {
                if($Params[1] eq "std::allocator<".$Params[0].">")
                { # std::vector<T, std::allocator<T> >
                    splice(@Params, 1, 1);
                }
            }
        }
        elsif($Short eq "std::set")
        {
            if($#Params==2)
            {
                if($Params[1] eq "std::less<".$Params[0].">"
                and $Params[2] eq "std::allocator<".$Params[0].">")
                { # std::set<T, std::less<T>, std::allocator<T> >
                    splice(@Params, 1, 2);
                }
            }
        }
        elsif($Short eq "std::basic_string")
        {
            if($#Params==2)
            {
                if($Params[1] eq "std::char_traits<".$Params[0].">"
                and $Params[2] eq "std::allocator<".$Params[0].">")
                { # std::basic_string<T, std::char_traits<T>, std::allocator<T> >
                    splice(@Params, 1, 2);
                }
            }
        }
        
        return ($Short, @Params);
    }
    
    return $Name; # error
}

sub getTypeInfo($)
{
    my $ID = $_[0];
    my $Kind = $DWARF_Info_Kind{$ID};
    
    if(defined $Cache{"getTypeInfo"}{$ID}) {
        return;
    }
    
    if(my $N = $NameSpace{$ID})
    {
        if($DWARF_Info_Kind{$N} eq "subprogram")
        { # local code
            # template instances are declared in the subprogram (constructor)
            my $Tmpl = 0;
            if(my $ObjP = $DWARF_Info{$N}{"object_pointer"})
            {
                while($DWARF_Info{$ObjP}{"type"}) {
                    $ObjP = $DWARF_Info{$ObjP}{"type"};
                }
                my $CName = $DWARF_Info{$ObjP}{"name"};
                $CName=~s/<.*//g;
                if($CName eq $DWARF_Info{$N}{"name"}) {
                    $Tmpl = 1;
                }
            }
            if(not $Tmpl)
            { # local types
                $LocalType{$ID} = 1;
            }
        }
        elsif($DWARF_Info_Kind{$N} eq "lexical_block")
        { # local code
            return;
        }
    }
    
    $Cache{"getTypeInfo"}{$ID} = 1;
    
    my %TInfo = ();
    
    $TInfo{"Type"} = $TypeType{$Kind};
    
    if(not $TInfo{"Type"})
    {
        if($DWARF_Info_Kind{$ID} eq "subroutine_type") {
            $TInfo{"Type"} = "Func";
        }
    }
    
    if(defined $ClassMethods{$ID})
    {
        if($TInfo{"Type"} eq "Struct") {
            $TInfo{"Type"} = "Class";
        }
    }
    
    if(my $BaseType = $DWARF_Info{$ID}{"type"})
    {
        $TInfo{"BaseType"} = $BaseType;
        
        if(defined $TypeType{$DWARF_Info_Kind{$BaseType}})
        {
            getTypeInfo($TInfo{"BaseType"});
            
            if(not defined $TypeInfo{$TInfo{"BaseType"}}
            or not $TypeInfo{$TInfo{"BaseType"}}{"Name"})
            { # local code
                delete($TypeInfo{$ID});
                return;
            }
        }
    }
    
    if($TInfo{"Type"} eq "Class") {
        $TInfo{"Copied"} = 1; # will be changed in getSymbolInfo()
    }
    
    if(defined $TypeMember{$ID})
    {
        my $Unnamed = 0;
        foreach my $Pos (sort {int($a) <=> int($b)} keys(%{$TypeMember{$ID}}))
        {
            my $MemId = $TypeMember{$ID}{$Pos};
            my %MInfo = %{$DWARF_Info{$MemId}};
            
            if(my $Name = $MInfo{"name"})
            {
                if(index($Name, "_vptr.")==0)
                { # v-table pointer
                    $Name="_vptr";
                }
                $TInfo{"Memb"}{$Pos}{"name"} = $Name;
            }
            else
            {
                $TInfo{"Memb"}{$Pos}{"name"} = "unnamed".$Unnamed;
                $Unnamed += 1;
            }
            if($TInfo{"Type"} eq "Enum") {
                $TInfo{"Memb"}{$Pos}{"value"} = $MInfo{"const_value"};
            }
            else
            {
                $TInfo{"Memb"}{$Pos}{"type"} = $MInfo{"type"};
                if(my $Access = $MInfo{"accessibility"}) {
                    $TInfo{"Memb"}{$Pos}{"access"} = $Access;
                }
                if($TInfo{"Type"} eq "Union") {
                    $TInfo{"Memb"}{$Pos}{"offset"} = "0";
                }
                elsif(defined $MInfo{"data_member_location"}) {
                    $TInfo{"Memb"}{$Pos}{"offset"} = $MInfo{"data_member_location"};
                }
            }
            
            if((my $BitSize = $MInfo{"bit_size"}) ne "") {
                $TInfo{"Memb"}{$Pos}{"bitfield"} = $BitSize;
            }
        }
    }
    
    if(my $Access = $DWARF_Info{$ID}{"accessibility"}) {
        $TInfo{ucfirst($Access)} = 1;
    }
    
    if(my $Size = $DWARF_Info{$ID}{"byte_size"}) {
        $TInfo{"Size"} = $Size;
    }
    
    setSource(\%TInfo, $ID, $DWARF_Info{$ID}{"decl_file"}, $DWARF_Info{$ID}{"decl_line"});
    
    if(not $DWARF_Info{$ID}{"name"}
    and my $Spec = $DWARF_Info{$ID}{"specification"}) {
        $DWARF_Info{$ID}{"name"} = $DWARF_Info{$Spec}{"name"};
    }
    
    if(my $Name = $DWARF_Info{$ID}{"name"})
    {
        $TInfo{"Name"} = $Name;
        
        if(my $NS = $NameSpace{$ID})
        {
            if($DWARF_Info_Kind{$NS} eq "namespace")
            {
                $NS = undef;
                my $ID_ = $ID;
                my @NSs = ();
                
                while($NS = $NameSpace{$ID_})
                {
                    push(@NSs, $DWARF_Info{$NS}{"name"});
                    $ID_ = $NS;
                }
                if(@NSs)
                {
                    $TInfo{"NameSpace"} = join("::", reverse(@NSs));
                    $TInfo{"Name"} = $TInfo{"NameSpace"}."::".$TInfo{"Name"};
                    
                    $NestedNameSpaces{$TInfo{"NameSpace"}} = 1;
                }
            }
            elsif($DWARF_Info_Kind{$NS} eq "class_type"
            or $DWARF_Info_Kind{$NS} eq "structure_type")
            { # class
                getTypeInfo($NS);
                
                $TInfo{"NameSpace"} = $TypeInfo{$NS}{"Name"};
                $TInfo{"NameSpace"}=~s/\Astruct //;
                $TInfo{"Name"} = $TInfo{"NameSpace"}."::".$TInfo{"Name"};
            }
        }
        
        if($TInfo{"Type"}=~/\A(Struct|Class)\Z/)
        {
            if(defined $VirtualTable{$TInfo{"Name"}}) {
                %{$TInfo{"VTable"}} = %{$VirtualTable{$TInfo{"Name"}}};
            }
        }
        
        if($TInfo{"Type"}=~/\A(Struct|Enum|Union)\Z/) {
            $TInfo{"Name"} = lc($TInfo{"Type"})." ".$TInfo{"Name"};
        }
    }
    
    if($TInfo{"Type"} eq "Pointer")
    {
        if($DWARF_Info_Kind{$TInfo{"BaseType"}} eq "subroutine_type")
        {
            init_FuncType(\%TInfo, $TInfo{"BaseType"}, "FuncPtr");
        }
    }
    elsif($TInfo{"Type"}=~/Typedef|Const|Volatile/)
    {
        if($DWARF_Info_Kind{$TInfo{"BaseType"}} eq "subroutine_type")
        {
            getTypeInfo($TInfo{"BaseType"});
        }
    }
    elsif($TInfo{"Type"} eq "Func")
    {
        init_FuncType(\%TInfo, $ID, "Func");
    }
    elsif($TInfo{"Type"} eq "Struct")
    {
        if(not $TInfo{"Name"}
        and my $Sb = $DWARF_Info{$ID}{"sibling"})
        {
            if($DWARF_Info_Kind{$Sb} eq "subroutine_type"
            and defined $TInfo{"Memb"}
            and $TInfo{"Memb"}{0}{"name"} eq "__pfn")
            { # __pfn and __delta
                $TInfo{"Type"} = "MethodPtr";
                
                my @Prms = ();
                my $PPos = 0;
                foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$FuncParam{$Sb}}))
                {
                    my $ParamId = $FuncParam{$Sb}{$Pos};
                    my %PInfo = %{$DWARF_Info{$ParamId}};
                    
                    if(defined $PInfo{"artificial"})
                    { # this
                        next;
                    }
                    
                    $TInfo{"Param"}{$PPos}{"type"} = $PInfo{"type"};
                    getTypeInfo($PInfo{"type"});
                    push(@Prms, $TypeInfo{$PInfo{"type"}}{"Name"});
                    
                    $PPos += 1;
                }
                
                if(my $ClassId = $DWARF_Info{$Sb}{"object_pointer"})
                {
                    while($DWARF_Info{$ClassId}{"type"}) {
                        $ClassId = $DWARF_Info{$ClassId}{"type"};
                    }
                    $TInfo{"Class"} = $ClassId;
                    getTypeInfo($TInfo{"Class"});
                }
                
                if($TInfo{"Return"} = $DWARF_Info{$Sb}{"type"}) {
                    getTypeInfo($TInfo{"Return"});
                }
                else
                { # void
                    $TInfo{"Return"} = "1";
                }
                
                $TInfo{"Name"} = $TypeInfo{$TInfo{"Return"}}{"Name"};
                $TInfo{"Name"} .= "(".$TypeInfo{$TInfo{"Class"}}{"Name"}."::*)";
                $TInfo{"Name"} .= "(".join(",", @Prms).")";
            }
        }
    }
    elsif($TInfo{"Type"} eq "FieldPtr")
    {
        $TInfo{"Return"} = $TInfo{"BaseType"};
        delete($TInfo{"BaseType"});
        
        if(my $Class = $DWARF_Info{$ID}{"containing_type"})
        {
            $TInfo{"Class"} = $Class;
            $TInfo{"Name"} = $TypeInfo{$TInfo{"Return"}}{"Name"}."(".$TypeInfo{$Class}{"Name"}."::*)";
        }
        
        $TInfo{"Size"} = $SYS_WORD;
    }
    
    foreach my $Pos (sort {int($a) <=> int($b)} keys(%{$Inheritance{$ID}}))
    {
        if(my $BaseId = $Inheritance{$ID}{$Pos}{"id"})
        {
            if(my $E = $SpecElem{$BaseId}) {
                $BaseId = $E;
            }
            
            $TInfo{"Base"}{$BaseId}{"pos"} = "$Pos";
            if(my $Access = $Inheritance{$ID}{$Pos}{"access"}) {
                $TInfo{"Base"}{$BaseId}{"access"} = $Access;
            }
            if($Inheritance{$ID}{$Pos}{"virtual"}) {
                $TInfo{"Base"}{$BaseId}{"virtual"} = 1;
            }
            
            $ClassChild{$BaseId}{$ID} = 1;
        }
    }
    
    if($TInfo{"Type"} eq "Pointer")
    {
        if(not $TInfo{"BaseType"})
        {
            $TInfo{"Name"} = "void*";
            $TInfo{"BaseType"} = "1";
        }
    }
    if($TInfo{"Type"} eq "Const")
    {
        if(not $TInfo{"BaseType"})
        {
            $TInfo{"Name"} = "const void";
            $TInfo{"BaseType"} = "1";
        }
    }
    if($TInfo{"Type"} eq "Volatile")
    {
        if(not $TInfo{"BaseType"})
        {
            $TInfo{"Name"} = "volatile void";
            $TInfo{"BaseType"} = "1";
        }
    }
    
    foreach my $Attr (keys(%TInfo)) {
        $TypeInfo{$ID}{$Attr} = $TInfo{$Attr};
    }
    
    if(my $BASE_ID = $DWARF_Info{$ID}{"specification"})
    {
        foreach my $Attr (keys(%{$TypeInfo{$BASE_ID}}))
        {
            if($Attr ne "Type") {
                $TypeInfo{$ID}{$Attr} = $TypeInfo{$BASE_ID}{$Attr};
            }
        }
        
        foreach my $Attr (keys(%{$TypeInfo{$ID}})) {
            $TypeInfo{$BASE_ID}{$Attr} = $TypeInfo{$ID}{$Attr};
        }
        
        $TypeSpec{$ID} = $BASE_ID;
        
        $ID = $BASE_ID;
    }
    
    if(not $TypeInfo{$ID}{"Name"})
    {
        my $ID_ = $ID;
        my $BaseID = undef;
        my $Name = "";
        
        while($BaseID = $DWARF_Info{$ID_}{"type"})
        {
            my $Kind = $DWARF_Info_Kind{$ID_};
            if(my $Q = $Qual{$TypeType{$Kind}})
            {
                $Name = $Q.$Name;
                if($Q=~/\A\w/) {
                    $Name = " ".$Name;
                }
            }
            if(my $BName = $TypeInfo{$BaseID}{"Name"})
            {
                $Name = $BName.$Name;
                last;
            }
            elsif(my $BName2 = $DWARF_Info{$BaseID}{"name"})
            {
                $Name = $BName2.$Name;
            }
            $ID_ = $BaseID;
        }
        
        $TypeInfo{$ID}{"Name"} = $Name;
        
        if($TInfo{"Type"} eq "Array")
        {
            if(my $Count = $ArrayCount{$ID})
            {
                $TypeInfo{$ID}{"Name"} .= "[".$Count."]";
                if(my $BSize = $TypeInfo{$TypeInfo{$ID}{"BaseType"}}{"Size"})
                {
                    if(my $Size = $Count*$BSize)
                    {
                        $TypeInfo{$ID}{"Size"} = "$Size";
                    }
                }
            }
            else
            {
                $TypeInfo{$ID}{"Name"} .= "[]";
                $TypeInfo{$ID}{"Size"} = $SYS_WORD;
            }
        }
    }
    
    if(my $Bid = $TypeInfo{$ID}{"BaseType"})
    {
        if(not $TypeInfo{$ID}{"Size"}
        and $TypeInfo{$Bid}{"Size"}) {
            $TypeInfo{$ID}{"Size"} = $TypeInfo{$Bid}{"Size"};
        }
    }
    $TypeInfo{$ID}{"Name"} = formatName($TypeInfo{$ID}{"Name"}, "T"); # simpleName()
    
    if($TypeInfo{$ID}{"Name"}=~/>\Z/)
    {
        my ($Short, @TParams) = get_TParams($TypeInfo{$ID}{"Name"});
        
        if(@TParams)
        {
            delete($TypeInfo{$ID}{"TParam"});
            foreach my $Pos (0 .. $#TParams) {
                $TypeInfo{$ID}{"TParam"}{$Pos}{"name"} = $TParams[$Pos];
            }
            $TypeInfo{$ID}{"Name"} = formatName($Short."<".join(", ", @TParams).">", "T");
        }
    }
    
    if(not $TypeInfo{$ID}{"Name"})
    {
        if($TInfo{"Type"}=~/\A(Struct|Enum|Union)\Z/)
        {
            if($TInfo{"Header"}) {
                $TypeInfo{$ID}{"Name"} = "anon-".lc($TInfo{"Type"})."-".$TInfo{"Header"}."-".$TInfo{"Line"};
            }
            else {
                $TypeInfo{$ID}{"Name"} = "anon-".lc($TInfo{"Type"})."-".$TInfo{"Source"}."-".$TInfo{"SourceLine"};
            }
        }
    }
    
    if(not defined $TName_Tid{$TypeInfo{$ID}{"Name"}}
    or $ID<$TName_Tid{$TypeInfo{$ID}{"Name"}})
    {
        $TName_Tid{$TypeInfo{$ID}{"Name"}} = "$ID";
    }
    
    if(defined $TypeInfo{$ID}{"Source"})
    {
        if(not defined $TypeInfo{$ID}{"Header"}) {
            $TypeInfo{$ID}{"Line"} = $TypeInfo{$ID}{"SourceLine"};
        }
        delete($TypeInfo{$ID}{"SourceLine"});
    }
}

sub setSource($$$$)
{
    my ($R, $Id, $File, $Line) = @_;
    
    my $Unit = $CompUnit{$Id};
    
    if(defined $File)
    {
        if($SourceFile{$Unit}{$File}=~/\.($HEADER_EXT)\Z/)
        {
            $R->{"Header"} = $SourceFile{$Unit}{$File};
            if(defined $Line) {
                $R->{"Line"} = $Line;
            }
        }
        elsif($SourceFile{$Unit}{$File} ne "<built-in>")
        {
            $R->{"Source"} = $SourceFile{$Unit}{$File};
            if(defined $Line) {
                $R->{"SourceLine"} = $Line;
            }
        }
    }
}

sub skipSymbol($)
{
    if($SkipCxx and not $STDCXX_TARGET)
    {
        if($_[0]=~/\A(_ZS|_ZNS|_ZNKS|_ZN9__gnu_cxx|_ZNK9__gnu_cxx|_ZTIS|_ZTSS)/)
        { # stdc++ symbols
            return 1;
        }
    }
    return 0;
}

sub find_center($$)
{
    my ($Name, $Target) = @_;
    my %B = ( "("=>0, "<"=>0, ")"=>0, ">"=>0 );
    foreach my $Pos (0 .. length($Name)-1)
    {
        my $S = substr($Name, length($Name)-1-$Pos, 1);
        if(defined $B{$S}) {
            $B{$S}+=1;
        }
        if($S eq $Target)
        {
            if($B{"("}==$B{")"}
            and $B{"<"}==$B{">"}) {
                return length($Name)-1-$Pos;
            }
        }
    }
    return 0;
}

sub isExternal($)
{
    my $ID = $_[0];
    
    if($DWARF_Info{$ID}{"external"}) {
        return 1;
    }
    elsif(my $Spec = $DWARF_Info{$ID}{"specification"})
    {
        if($DWARF_Info{$Spec}{"external"}) {
            return 1;
        }
    }
    
    return 0;
}

sub get_Mangled($)
{
    my $ID = $_[0];
    
    if(my $Low_Pc = $DWARF_Info{$ID}{"low_pc"})
    {
        if($Low_Pc=~/<([\w\@\.]+)>/) {
            return $1;
        }
    }
    
    if(my $Loc = $DWARF_Info{$ID}{"location"})
    {
        if($Loc=~/<([\w\@\.]+)>/) {
            return $1;
        }
    }
    
    return undef;
}

sub getSymbolInfo($)
{
    my $ID = $_[0];
    
    my $ShortName = $DWARF_Info{$ID}{"name"};
    my $MnglName = get_Mangled($ID);
    
    if(not $MnglName)
    {
        if(my $Sp = $SpecElem{$ID}) {
            $MnglName = get_Mangled($Sp);
        }
    }
    
    if(not $MnglName)
    {
        if(index($ShortName, "<")!=-1)
        { # template
            return;
        }
        $MnglName = $ShortName;
    }
    
    if(skipSymbol($MnglName)) {
        return;
    }
    
    if(index($MnglName, "\@")!=-1) {
        $MnglName=~s/([\@]+.*?)\Z//;
    }
    
    if(not $MnglName) {
        return;
    }
    
    if(index($MnglName, ".")!=-1)
    { # foo.part.14
      # bar.isra.15
        return;
    }
    
    if($MnglName=~/\W/)
    { # unmangled operators, etc.
        return;
    }
    
    if(my $N = $NameSpace{$ID})
    {
        if($DWARF_Info_Kind{$N} eq "lexical_block"
        or $DWARF_Info_Kind{$N} eq "subprogram")
        { # local variables
            return;
        }
    }
    
    if($Mangled_ID{$MnglName})
    { # duplicates
        if(defined $Checked_Spec{$MnglName}
        or not $DWARF_Info{$ID}{"specification"})
        { # add spec info
            return;
        }
    }
    
    my %SInfo = ();
    
    if($ShortName) {
        $SInfo{"ShortName"} = $ShortName;
    }
    $SInfo{"MnglName"} = $MnglName;
    
    if($MnglName eq $ShortName)
    {
        delete($SInfo{"MnglName"});
        $MnglName = $ShortName;
    }
    elsif(index($MnglName, "_Z")!=0)
    {
        if($SInfo{"ShortName"})
        {
            $SInfo{"Alias"} = $SInfo{"ShortName"};
            $SInfo{"ShortName"} = $SInfo{"MnglName"};
        }
        
        delete($SInfo{"MnglName"});
        $MnglName = $ShortName;
    }
    
    if(not $SInfo{"Alias"})
    {
        if(my $Linkage = $DWARF_Info{$ID}{"linkage_name"}) {
            $SInfo{"Alias"} = $Linkage;
        }
    }
    
    if($DWARF_Info_Kind{$ID} eq "subprogram")
    {
        if(isExternal($ID)) {
            $SInfo{"External"} = 1;
        }
    }
    
    if(index($MnglName, "_ZNVK")==0)
    {
        $SInfo{"Const"} = 1;
        $SInfo{"Volatile"} = 1;
    }
    elsif(index($MnglName, "_ZNV")==0) {
        $SInfo{"Volatile"} = 1;
    }
    elsif(index($MnglName, "_ZNK")==0) {
        $SInfo{"Const"} = 1;
    }
    
    if($DWARF_Info{$ID}{"artificial"}) {
        $SInfo{"Artificial"} = 1;
    }
    
    my ($C, $D) = ();
    
    if(index($MnglName, "C1E")!=-1
    or index($MnglName, "C2E")!=-1)
    {
        $C = 1;
        $SInfo{"Constructor"} = 1;
    }
    
    if(index($MnglName, "D1E")!=-1
    or index($MnglName, "D2E")!=-1
    or index($MnglName, "D0E")!=-1)
    {
        $D = 1;
        $SInfo{"Destructor"} = 1;
    }
    
    if($C or $D)
    {
        if(my $Orig = $DWARF_Info{$ID}{"abstract_origin"})
        {
            if(my $InLine = $DWARF_Info{$Orig}{"inline"})
            {
                if(index($InLine, "declared_not_inlined")==0)
                {
                    $SInfo{"InLine"} = 1;
                    $SInfo{"Artificial"} = 1;
                }
            }
            
            my %OrigInfo = %{$DWARF_Info{$Orig}};
            
            setSource(\%SInfo, $Orig, $OrigInfo{"decl_file"}, $OrigInfo{"decl_line"});
            
            if(my $Spec = $DWARF_Info{$Orig}{"specification"})
            {
                my %SpecInfo = %{$DWARF_Info{$Spec}};
                setSource(\%SInfo, $Spec, $SpecInfo{"decl_file"}, $SpecInfo{"decl_line"});
                
                $SInfo{"ShortName"} = $SpecInfo{"name"};
                if($D) {
                    $SInfo{"ShortName"}=~s/\A\~//g;
                }
                
                if(my $Class = $NameSpace{$Spec}) {
                    $SInfo{"Class"} = $Class;
                }
                
                if(my $Virt = $DWARF_Info{$Spec}{"virtuality"})
                {
                    if(index($Virt, "virtual")!=-1) {
                        $SInfo{"Virt"} = 1;
                    }
                }
                
                if(my $Access = $DWARF_Info{$Spec}{"accessibility"}) {
                    $SInfo{ucfirst($Access)} = 1;
                }
                
                # clean origin
                delete($SymbolInfo{$Spec});
            }
        }
    }
    else
    {
        if(my $InLine = $DWARF_Info{$ID}{"inline"})
        {
            if(index($InLine, "declared_inlined")==0) {
                $SInfo{"InLine"} = 1;
            }
        }
    }
    
    if($DWARF_Info_Kind{$ID} eq "variable")
    { # global data
        $SInfo{"Data"} = 1;
        
        if(my $Spec = $DWARF_Info{$ID}{"specification"})
        {
            if($DWARF_Info_Kind{$Spec} eq "member")
            {
                my %SpecInfo = %{$DWARF_Info{$Spec}};
                setSource(\%SInfo, $Spec, $SpecInfo{"decl_file"}, $SpecInfo{"decl_line"});
                $SInfo{"ShortName"} = $SpecInfo{"name"};
                
                if(my $NSp = $NameSpace{$Spec})
                {
                    if($DWARF_Info_Kind{$NSp} eq "namespace") {
                        $SInfo{"NameSpace"} = $DWARF_Info{$NSp}{"name"};
                    }
                    else {
                        $SInfo{"Class"} = $NSp;
                    }
                }
            }
        }
    }
    
    if(my $Access = $DWARF_Info{$ID}{"accessibility"})
    {
        $SInfo{ucfirst($Access)} = 1;
    }
    
    if(my $Class = $DWARF_Info{$ID}{"containing_type"})
    {
        $SInfo{"Class"} = $Class;
    }
    if(my $NS = $NameSpace{$ID})
    {
        if($DWARF_Info_Kind{$NS} eq "namespace") {
            $SInfo{"NameSpace"} = $DWARF_Info{$NS}{"name"};
        }
        else {
            $SInfo{"Class"} = $NS;
        }
    }
    
    if($SInfo{"Class"}
    and index($MnglName, "_Z")!=0)
    {
        return;
    }
    
    if(my $Return = $DWARF_Info{$ID}{"type"})
    {
        $SInfo{"Return"} = $Return;
    }
    
    if($SInfo{"ShortName"}=~/>\Z/)
    { # foo<T1, T2, ...>
        my ($Short, @TParams) = get_TParams($SInfo{"ShortName"});
        if(@TParams)
        {
            foreach my $Pos (0 .. $#TParams) {
                $SInfo{"TParam"}{$Pos}{"name"} = formatName($TParams[$Pos], "T");
            }
            # simplify short name
            $SInfo{"ShortName"} = $Short.formatName("<".join(", ", @TParams).">", "T");
        }
    }
    elsif($SInfo{"ShortName"}=~/\Aoperator (\w.*)\Z/)
    { # operator type<T1>::name
        $SInfo{"ShortName"} = "operator ".simpleName($1);
    }
    
    if(my $Virt = $DWARF_Info{$ID}{"virtuality"})
    {
        if(index($Virt, "virtual")!=-1)
        {
            if($D) {
                $SInfo{"Virt"} = 1;
            }
            else {
                $SInfo{"PureVirt"} = 1;
            }
        }
        
        if((my $VirtPos = $DWARF_Info{$ID}{"vtable_elem_location"}) ne "")
        {
            $SInfo{"VirtPos"} = $VirtPos;
        }
    }
    
    setSource(\%SInfo, $ID, $DWARF_Info{$ID}{"decl_file"}, $DWARF_Info{$ID}{"decl_line"});
    
    if($SInfo{"Class"}
    and not $SInfo{"Data"})
    {
        $SInfo{"Static"} = 1;
    }
    
    my $PPos = 0;
    
    foreach my $Pos (sort {int($a) <=> int($b)} keys(%{$FuncParam{$ID}}))
    {
        my $ParamId = $FuncParam{$ID}{$Pos};
        my $Offset = undef;
        my $Reg = undef;
        
        if((my $Loc = $DWARF_Info{$ParamId}{"location"}) ne "") {
            $Offset = $Loc;
        }
        elsif((my $R = $DWARF_Info{$ParamId}{"register"}) ne "") {
            $Reg = $RegName{$R};
        }
        elsif((my $LL = $DWARF_Info{$ParamId}{"location_list"}) ne "")
        {
            if(my $L = $DebugLoc{$LL})
            {
                if($L=~/reg(\d+)/) {
                    $Reg = $RegName{$1};
                }
            }
        }
        
        if(my $Orig = $DWARF_Info{$ParamId}{"abstract_origin"}) {
            $ParamId = $Orig;
        }
        
        my %PInfo = %{$DWARF_Info{$ParamId}};
        
        if(defined $PInfo{"artificial"})
        { # this
            delete($SInfo{"Static"});
            next;
        }
        
        if(defined $Offset) {
            $SInfo{"Param"}{$PPos}{"offset"} = $Offset;
        }
        
        $SInfo{"Param"}{$PPos}{"type"} = $PInfo{"type"};
        
        if(defined $PInfo{"name"}) {
            $SInfo{"Param"}{$PPos}{"name"} = $PInfo{"name"};
        }
        elsif($TypeInfo{$PInfo{"type"}}{"Name"} ne "...") {
            $SInfo{"Param"}{$PPos}{"name"} = "p".($PPos+1);
        }
        if(defined $Reg)
        { # FIXME: 0+8, 1+16, etc. (for partially distributed parameters)
            $SInfo{"Reg"}{$PPos} = $Reg;
        }
        $PPos += 1;
    }
    
    if($SInfo{"Constructor"} and not $SInfo{"InLine"}) {
        delete($TypeInfo{$SInfo{"Class"}}{"Copied"});
    }
    
    if(my $BASE_ID = $Mangled_ID{$MnglName})
    {
        $ID = $BASE_ID;
        
        if(defined $SymbolInfo{$ID}{"PureVirt"})
        {
            delete($SymbolInfo{$ID}{"PureVirt"});
            $SymbolInfo{$ID}{"Virt"} = 1;
        }
    }
    $Mangled_ID{$MnglName} = $ID;
    
    if($DWARF_Info{$ID}{"specification"}) {
        $Checked_Spec{$MnglName} = 1;
    }
    
    foreach my $Attr (keys(%SInfo)) {
        $SymbolInfo{$ID}{$Attr} = $SInfo{$Attr};
    }
}

sub getTypeIdByName($)
{
    my $Name = $_[0];
    return $TName_Tid{formatName($Name, "T")};
}

sub getFirst($)
{
    my $Tid = $_[0];
    if(not $Tid) {
        return $Tid;
    }
    
    if(defined $TypeSpec{$Tid}) {
        $Tid = $TypeSpec{$Tid};
    }
    
    my $F = 0;
    
    if(my $N = $TypeInfo{$Tid}{"Name"})
    {
        my $Type = $TypeInfo{$Tid}{"Type"};
        if($N=~s/\Astruct //)
        { # search for class
            $F = 1;
        }
        foreach my $P ("", "struct ", "union ", "enum ")
        { # class, struct, ...
            if(defined $TName_Tid{$P.$N})
            {
                if(my $FTid = $TName_Tid{$P.$N})
                {
                    my $Type2 = $TypeInfo{$FTid}{"Type"};
                    if($Type eq "Typedef")
                    {
                        if($Type2 ne "Typedef") {
                            next;
                        }
                    }
                    elsif($Type=~/Struct|Class/)
                    {
                        if($Type2!~/Struct|Class/) {
                            next;
                        }
                    }
                    if($F and not $P
                    and $FTid ne $Tid)
                    {
                        $MergedTypes{$Tid} = 1;
                    }
                    return "$FTid";
                }
            }
        }
        printMsg("ERROR", "internal error (missed type id $Tid)");
    }
    
    return $Tid;
}

sub searchTypeID($)
{
    my $N = $_[0];
    foreach my $P ("", "struct ", "union ", "enum ")
    {
        if(my $Tid = $TName_Tid{$P.$N})
        {
            return $Tid;
        }
    }
    return undef;
}

sub remove_Unused()
{ # remove unused data types from the ABI dump
    %HeadersInfo = ();
    %SourcesInfo = ();
    
    my (%SelectedHeaders, %SelectedSources) = ();
    
    foreach my $ID (sort {int($a)<=>int($b)} keys(%SymbolInfo))
    {
        if($SelectedSymbols{$ID}==2)
        { # data, inline, pure
            next;
        }
        
        register_SymbolUsage($ID);
        
        if(my $H = $SymbolInfo{$ID}{"Header"}) {
            $SelectedHeaders{$H} = 1;
        }
        if(my $S = $SymbolInfo{$ID}{"Source"}) {
            $SelectedSources{$S} = 1;
        }
    }
    
    foreach my $ID (sort {int($a)<=>int($b)} keys(%SymbolInfo))
    {
        if($SelectedSymbols{$ID}==2)
        { # data, inline, pure
            my $Save = 0;
            if(my $Class = $SymbolInfo{$ID}{"Class"})
            {
                if(defined $UsedType{$Class}) {
                    $Save = 1;
                }
                else
                {
                    foreach (keys(%{$ClassChild{$Class}}))
                    {
                        if(defined $UsedType{$_})
                        {
                            $Save = 1;
                            last;
                        }
                    }
                }
            }
            if(my $Header = $SymbolInfo{$ID}{"Header"})
            {
                if(defined $SelectedHeaders{$Header}) {
                    $Save = 1;
                }
            }
            if(my $Source = $SymbolInfo{$ID}{"Source"})
            {
                if(defined $SelectedSources{$Source}) {
                    $Save = 1;
                }
            }
            if($Save) {
                register_SymbolUsage($ID);
            }
            else {
                delete($SymbolInfo{$ID});
            }
        }
    }
    
    if(defined $AllTypes)
    {
        # register all data types (except anon structs and unions)
        foreach my $Tid (keys(%TypeInfo))
        {
            if(defined $LocalType{$Tid})
            { # except local code
                next;
            }
            if($TypeInfo{$Tid}{"Type"} eq "Enum"
            or index($TypeInfo{$Tid}{"Name"}, "anon-")!=0) {
                register_TypeUsage($Tid);
            }
        }
        
        # remove unused anons (except enums)
        foreach my $Tid (keys(%TypeInfo))
        {
            if(not $UsedType{$Tid})
            {
                if($TypeInfo{$Tid}{"Type"} ne "Enum")
                {
                    if(index($TypeInfo{$Tid}{"Name"}, "anon-")==0) {
                        delete($TypeInfo{$Tid});
                    }
                }
            }
        }
        
        # remove duplicates
        foreach my $Tid (keys(%TypeInfo))
        {
            my $Name = $TypeInfo{$Tid}{"Name"};
            if($TName_Tid{$Name} ne $Tid) {
                delete($TypeInfo{$Tid});
            }
        }
    }
    else
    {
        foreach my $Tid (keys(%TypeInfo))
        { # remove unused types
            if(not $UsedType{$Tid}) {
                delete($TypeInfo{$Tid});
            }
        }
    }
    
    foreach my $Tid (keys(%MergedTypes)) {
        delete($TypeInfo{$Tid});
    }
    
    foreach my $Tid (keys(%LocalType))
    {
        if(not $UsedType{$Tid}) {
            delete($TypeInfo{$Tid});
        }
    }
    
    # completeness
    foreach my $Tid (keys(%TypeInfo)) {
        check_Completeness($TypeInfo{$Tid});
    }
    
    foreach my $Sid (keys(%SymbolInfo)) {
        check_Completeness($SymbolInfo{$Sid});
    }
    
    # clean memory
    %UsedType = ();
}

sub simpleName($)
{
    my $N = $_[0];
    
    if(index($N, "std::basic_string")!=-1)
    {
        $N=~s/std::basic_string<char, std::char_traits<char>, std::allocator<char> >/std::string /g;
        $N=~s/std::basic_string<char>/std::string /g;
    }
    
    return formatName($N, "T");
}

sub register_SymbolUsage($)
{
    my $InfoId = $_[0];
    
    my %FuncInfo = %{$SymbolInfo{$InfoId}};
    
    if(my $S = $FuncInfo{"Source"}) {
        $SourcesInfo{$S} = 1;
    }
    if(my $H = $FuncInfo{"Header"}) {
        $HeadersInfo{$H} = 1;
    }
    if(my $RTid = getFirst($FuncInfo{"Return"}))
    {
        register_TypeUsage($RTid);
        $SymbolInfo{$InfoId}{"Return"} = $RTid;
    }
    if(my $FCid = getFirst($FuncInfo{"Class"}))
    {
        register_TypeUsage($FCid);
        $SymbolInfo{$InfoId}{"Class"} = $FCid;
        
        if(my $ThisId = getTypeIdByName($TypeInfo{$FCid}{"Name"}."*const"))
        { # register "this" pointer
            register_TypeUsage($ThisId);
        }
        if(my $ThisId_C = getTypeIdByName($TypeInfo{$FCid}{"Name"}." const*const"))
        { # register "this" pointer (const method)
            register_TypeUsage($ThisId_C);
        }
    }
    foreach my $PPos (keys(%{$FuncInfo{"Param"}}))
    {
        if(my $PTid = getFirst($FuncInfo{"Param"}{$PPos}{"type"}))
        {
            register_TypeUsage($PTid);
            $SymbolInfo{$InfoId}{"Param"}{$PPos}{"type"} = $PTid;
        }
    }
    foreach my $TPos (keys(%{$FuncInfo{"TParam"}}))
    {
        my $TPName = $FuncInfo{"TParam"}{$TPos}{"name"};
        if(my $TTid = searchTypeID($TPName))
        {
            if(my $FTTid = getFirst($TTid)) {
                register_TypeUsage($FTTid);
            }
        }
    }
}

sub register_TypeUsage($)
{
    my $TypeId = $_[0];
    if(not $TypeId) {
        return 0;
    }
    if($UsedType{$TypeId})
    { # already registered
        return 1;
    }
    my %TInfo = %{$TypeInfo{$TypeId}};
    
    if(my $S = $TInfo{"Source"}) {
        $SourcesInfo{$S} = 1;
    }
    if(my $H = $TInfo{"Header"}) {
        $HeadersInfo{$H} = 1;
    }
    
    if($TInfo{"Type"})
    {
        if($TInfo{"Type"}=~/\A(Struct|Union|Class|FuncPtr|Func|MethodPtr|FieldPtr|Enum)\Z/)
        {
            $UsedType{$TypeId} = 1;
            if($TInfo{"Type"}=~/\A(Struct|Class)\Z/)
            {
                foreach my $BaseId (keys(%{$TInfo{"Base"}}))
                { # register base classes
                    if(my $FBaseId = getFirst($BaseId))
                    {
                        register_TypeUsage($FBaseId);
                        if($FBaseId ne $BaseId)
                        {
                            %{$TypeInfo{$TypeId}{"Base"}{$FBaseId}} = %{$TypeInfo{$TypeId}{"Base"}{$BaseId}};
                            delete($TypeInfo{$TypeId}{"Base"}{$BaseId});
                        }
                    }
                }
                foreach my $TPos (keys(%{$TInfo{"TParam"}}))
                {
                    my $TPName = $TInfo{"TParam"}{$TPos}{"name"};
                    if(my $TTid = searchTypeID($TPName))
                    {
                        if(my $FTTid = getFirst($TTid)) {
                            register_TypeUsage($FTTid);
                        }
                    }
                }
            }
            foreach my $Memb_Pos (keys(%{$TInfo{"Memb"}}))
            {
                if(my $MTid = getFirst($TInfo{"Memb"}{$Memb_Pos}{"type"}))
                {
                    register_TypeUsage($MTid);
                    $TypeInfo{$TypeId}{"Memb"}{$Memb_Pos}{"type"} = $MTid;
                }
            }
            if($TInfo{"Type"} eq "FuncPtr"
            or $TInfo{"Type"} eq "MethodPtr"
            or $TInfo{"Type"} eq "Func")
            {
                if(my $RTid = getFirst($TInfo{"Return"}))
                {
                    register_TypeUsage($RTid);
                    $TypeInfo{$TypeId}{"Return"} = $RTid;
                }
                foreach my $Memb_Pos (keys(%{$TInfo{"Param"}}))
                {
                    if(my $MTid = getFirst($TInfo{"Param"}{$Memb_Pos}{"type"}))
                    {
                        register_TypeUsage($MTid);
                        $TypeInfo{$TypeId}{"Param"}{$Memb_Pos}{"type"} = $MTid;
                    }
                }
            }
            if($TInfo{"Type"} eq "FieldPtr")
            {
                if(my $RTid = getFirst($TInfo{"Return"}))
                {
                    register_TypeUsage($RTid);
                    $TypeInfo{$TypeId}{"Return"} = $RTid;
                }
                if(my $CTid = getFirst($TInfo{"Class"}))
                {
                    register_TypeUsage($CTid);
                    $TypeInfo{$TypeId}{"Class"} = $CTid;
                }
            }
            if($TInfo{"Type"} eq "MethodPtr")
            {
                if(my $CTid = getFirst($TInfo{"Class"}))
                {
                    register_TypeUsage($CTid);
                    $TypeInfo{$TypeId}{"Class"} = $CTid;
                }
            }
            return 1;
        }
        elsif($TInfo{"Type"}=~/\A(Const|ConstVolatile|Volatile|Pointer|Ref|Restrict|Array|Typedef)\Z/)
        {
            $UsedType{$TypeId} = 1;
            if(my $BTid = getFirst($TInfo{"BaseType"}))
            {
                register_TypeUsage($BTid);
                $TypeInfo{$TypeId}{"BaseType"} = $BTid;
            }
            return 1;
        }
        elsif($TInfo{"Type"} eq "Intrinsic")
        {
            $UsedType{$TypeId} = 1;
            return 1;
        }
    }
    return 0;
}

my %CheckedType = ();

sub check_Completeness($)
{
    my $Info = $_[0];
    
    # data types
    if(defined $Info->{"Memb"})
    {
        foreach my $Pos (keys(%{$Info->{"Memb"}}))
        {
            if(defined $Info->{"Memb"}{$Pos}{"type"}) {
                check_TypeInfo($Info->{"Memb"}{$Pos}{"type"});
            }
        }
    }
    if(defined $Info->{"Base"})
    {
        foreach my $Bid (keys(%{$Info->{"Base"}})) {
            check_TypeInfo($Bid);
        }
    }
    if(defined $Info->{"BaseType"}) {
        check_TypeInfo($Info->{"BaseType"});
    }
    if(defined $Info->{"TParam"})
    {
        foreach my $Pos (keys(%{$Info->{"TParam"}}))
        {
            my $TName = $Info->{"TParam"}{$Pos}{"name"};
            if($TName=~/\A(true|false|\d.*)\Z/) {
                next;
            }
            my $Found = 0;
            
            if(my $Tid = searchTypeID($TName)) {
                check_TypeInfo($Tid);
            }
            else
            {
                if(defined $Loud) {
                    printMsg("WARNING", "missed type $TName");
                }
            }
        }
    }
    
    # symbols
    if(defined $Info->{"Param"})
    {
        foreach my $Pos (keys(%{$Info->{"Param"}}))
        {
            if(defined $Info->{"Param"}{$Pos}{"type"}) {
                check_TypeInfo($Info->{"Param"}{$Pos}{"type"});
            }
        }
    }
    if(defined $Info->{"Return"}) {
        check_TypeInfo($Info->{"Return"});
    }
    if(defined $Info->{"Class"}) {
        check_TypeInfo($Info->{"Class"});
    }
}

sub check_TypeInfo($)
{
    my $Tid = $_[0];
    
    if(defined $CheckedType{$Tid}) {
        return;
    }
    $CheckedType{$Tid} = 1;
    
    if(defined $TypeInfo{$Tid})
    {
        if(not $TypeInfo{$Tid}{"Name"}) {
            printMsg("ERROR", "missed type name ($Tid)");
        }
        check_Completeness($TypeInfo{$Tid});
    }
    else {
        printMsg("ERROR", "missed type id $Tid");
    }
}

sub init_Registers()
{
    if($SYS_ARCH eq "x86")
    {
        %RegName = (
        # integer registers
        # 32 bits
            "0"=>"eax",
            "1"=>"ecx",
            "2"=>"edx",
            "3"=>"ebx",
            "4"=>"esp",
            "5"=>"ebp",
            "6"=>"esi",
            "7"=>"edi",
            "8"=>"eip",
            "9"=>"eflags",
            "10"=>"trapno",
        # FPU-control registers
        # 16 bits
            "37"=>"fctrl",
            "38"=>"fstat",
        # 32 bits
            "39"=>"mxcsr",
        # MMX registers
        # 64 bits
            "29"=>"mm0",
            "30"=>"mm1",
            "31"=>"mm2",
            "32"=>"mm3",
            "33"=>"mm4",
            "34"=>"mm5",
            "35"=>"mm6",
            "36"=>"mm7",
        # SSE registers
        # 128 bits
            "21"=>"xmm0",
            "22"=>"xmm1",
            "23"=>"xmm2",
            "24"=>"xmm3",
            "25"=>"xmm4",
            "26"=>"xmm5",
            "27"=>"xmm6",
            "28"=>"xmm7",
        # segment registers
        # 16 bits
            "40"=>"es",
            "41"=>"cs",
            "42"=>"ss",
            "43"=>"ds",
            "44"=>"fs",
            "45"=>"gs",
        # x87 registers
        # 80 bits
            "11"=>"st0",
            "12"=>"st1",
            "13"=>"st2",
            "14"=>"st3",
            "15"=>"st4",
            "16"=>"st5",
            "17"=>"st6",
            "18"=>"st7"
        );
    }
    elsif($SYS_ARCH eq "x86_64")
    {
        %RegName = (
        # integer registers
        # 64 bits
            "1"=>"rdx",
            "2"=>"rcx",
            "3"=>"rbx",
            "4"=>"rsi",
            "5"=>"rdi",
            "6"=>"rbp",
            "7"=>"rsp",
            "8"=>"r8",
            "9"=>"r9",
            "10"=>"r10",
            "11"=>"r11",
            "12"=>"r12",
            "13"=>"r13",
            "14"=>"r14",
            "15"=>"r15",
            "16"=>"rip",
            "49"=>"rflags",
        # MMX registers
        # 64 bits
            "41"=>"mm0",
            "42"=>"mm1",
            "43"=>"mm2",
            "44"=>"mm3",
            "45"=>"mm4",
            "46"=>"mm5",
            "47"=>"mm6",
            "48"=>"mm7",
        # SSE registers
        # 128 bits
            "17"=>"xmm0",
            "18"=>"xmm1",
            "19"=>"xmm2",
            "20"=>"xmm3",
            "21"=>"xmm4",
            "22"=>"xmm5",
            "23"=>"xmm6",
            "24"=>"xmm7",
            "25"=>"xmm8",
            "26"=>"xmm9",
            "27"=>"xmm10",
            "28"=>"xmm11",
            "29"=>"xmm12",
            "30"=>"xmm13",
            "31"=>"xmm14",
            "32"=>"xmm15",
        # control registers
        # 64 bits
            "62"=>"tr", 
            "63"=>"ldtr",
            "64"=>"mxcsr",
        # 16 bits
            "65"=>"fcw",
            "66"=>"fsw",
        # segment registers
        # 16 bits
            "50"=>"es",
            "51"=>"cs",
            "52"=>"ss",
            "53"=>"ds",
            "54"=>"fs",
            "55"=>"gs",
        # 64 bits
            "58"=>"fs.base",
            "59"=>"gs.base",
        # x87 registers
        # 80 bits
            "33"=>"st0",
            "34"=>"st1",
            "35"=>"st2",
            "36"=>"st3",
            "37"=>"st4",
            "38"=>"st5",
            "39"=>"st6",
            "40"=>"st7"
        );
    }
    elsif($SYS_ARCH eq "arm")
    {
        %RegName = (
        # integer registers
        # 32-bit
            " 0"=>"r0",
            " 1"=>"r1",
            " 2"=>"r2",
            " 3"=>"r3",
            " 4"=>"r4",
            " 5"=>"r5",
            " 6"=>"r6",
            " 7"=>"r7",
            " 8"=>"r8",
            " 9"=>"r9",
            "10"=>"r10",
            "11"=>"r11",
            "12"=>"r12",
            "13"=>"r13",
            "14"=>"r14",
            "15"=>"r15"
        );
    }
}

sub dump_sorting($)
{
    my $Hash = $_[0];
    return [] if(not $Hash);
    my @Keys = keys(%{$Hash});
    return [] if($#Keys<0);
    if($Keys[0]=~/\A\d+\Z/)
    { # numbers
        return [sort {int($a)<=>int($b)} @Keys];
    }
    else
    { # strings
        return [sort {$a cmp $b} @Keys];
    }
}

sub scenario()
{
    if($Help)
    {
        HELP_MESSAGE();
        exit(0);
    }
    if($ShowVersion)
    {
        printMsg("INFO", "ABI Dumper $TOOL_VERSION\nCopyright (C) 2013 ROSA Laboratory\nLicense: LGPL or GPL <http://www.gnu.org/licenses/>\nThis program is free software: you can redistribute it and/or modify it.\n\nWritten by Andrey Ponomarenko.");
        exit(0);
    }
    if($DumpVersion)
    {
        printMsg("INFO", $TOOL_VERSION);
        exit(0);
    }
    
    $Data::Dumper::Sortkeys = 1;
    
    if($SortDump) {
        $Data::Dumper::Sortkeys = \&dump_sorting;
    }
    
    if($FullDump)
    {
        $AllTypes = 1;
        $AllSymbols = 1;
    }
    
    if(not $OutputDump) {
        $OutputDump = "ABI.dump";
    }
    
    if(not @ARGV) {
        exitStatus("Error", "object path is not specified");
    }
    
    my $Res = 0;
    
    foreach my $Obj (@ARGV)
    {
        if(not -e $Obj) {
            exitStatus("Access_Error", "can't access \'$Obj\'");
        }
        
        $TargetName = get_filename(realpath($Obj));
        $TargetName=~s/\.debug\Z//; # nouveau.ko.debug
        
        if(index($TargetName, "libstdc++.so")==0) {
            $STDCXX_TARGET = 1;
        }
        
        read_Symbols($Obj);
        $Res += read_DWARF_Info($Obj);
        read_Vtables($Obj);
    }
    
    if(not $Res) {
        exitStatus("Access_Error", "can't find debug info in object(s)");
    }
    
    init_Registers();
    read_ABI();
    
    remove_Unused();
    
    dump_ABI();
}

scenario();