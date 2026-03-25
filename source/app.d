module app;

import argparse;
import std.stdio : writeln, writefln, stderr;
import std.string : format;
import std.path : baseName, stripExtension;
import api;

// ---------------------------------------------------------------------------
// Subcommand structs
// ---------------------------------------------------------------------------

@(Command("list").Description("List all households and their Creative Tonies"))
struct List {}

@(Command("clear").Description("Clear all chapters from a Creative Tonie"))
struct Clear
{
    @(NamedArgument("tonie").Description("Name of the Creative Tonie to clear").Required)
    string tonie;

    @(NamedArgument("household").Description("Name of the household (default: first household)"))
    string household;
}

@(Command("upload").Description("Upload audio files to a Creative Tonie"))
struct Upload
{
    @(NamedArgument("tonie").Description("Name of the Creative Tonie to upload to").Required)
    string tonie;

    @(NamedArgument("household").Description("Name of the household (default: first household)"))
    string household;

    @(PositionalArgument(0).Description("Audio files to upload"))
    string[] files;
}

// ---------------------------------------------------------------------------
// Top-level program
// ---------------------------------------------------------------------------

@(Command("donie2").Description("Manage Creative Tonies via the Tonie Cloud API"))
struct Program
{
    @(NamedArgument(["email", "e"]).Description("Tonie account email").Required)
    string email;

    @(NamedArgument(["password", "p"]).Description("Tonie account password").Required)
    string password;

    SubCommand!(List, Clear, Upload) cmd;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private Household resolveHousehold(Household[] households, string name)
{
    if (name.length == 0)
        return households[0];

    foreach (h; households)
        if (h.name == name)
            return h;

    throw new Exception(format!"Household '%s' not found. Available: %-(%s, %)"(
            name, households));
}

private CreativeTonie resolveTonie(CreativeTonie[] tonies, string name)
{
    foreach (t; tonies)
        if (t.name == name)
            return t;

    throw new Exception(format!"Creative Tonie '%s' not found. Available: %-(%s, %)"(
            name, tonies));
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

mixin CLI!Program.main!((prog) {
    try
    {
        string token = authenticate(prog.email, prog.password);

        return prog.cmd.matchCmd!(
            (List _)
            {
                auto households = getHouseholds(token);
                foreach (h; households)
                {
                    writefln!"Household: %s (id: %s)"(h.name, h.id);
                    auto tonies = getCreativeTonies(token, h.id);
                    foreach (t; tonies)
                    {
                        writefln!"  Tonie: %s (id: %s, chapters: %d, %.0fs used)"(
                            t.name, t.id, t.chaptersPresent, t.secondsPresent);
                    }
                }
                return 0;
            },
            (Clear cmd)
            {
                auto households = getHouseholds(token);
                auto household  = resolveHousehold(households, cmd.household);
                auto tonies     = getCreativeTonies(token, household.id);
                auto tonie      = resolveTonie(tonies, cmd.tonie);

                writefln!"Clearing all chapters from '%s' ..."(tonie.name);
                clearChapters(token, household.id, tonie.id);
                writeln("Done.");
                return 0;
            },
            (Upload cmd)
            {
                if (cmd.files.length == 0)
                {
                    stderr.writeln("Error: no files specified for upload.");
                    return 1;
                }

                auto households = getHouseholds(token);
                auto household  = resolveHousehold(households, cmd.household);
                auto tonies     = getCreativeTonies(token, household.id);
                auto tonie      = resolveTonie(tonies, cmd.tonie);

                foreach (file; cmd.files)
                {
                    string title = stripExtension(baseName(file));
                    writefln!"Uploading '%s' as chapter '%s' ..."(file, title);

                    auto uploadReq = requestUploadUrl(token);
                    uploadToS3(uploadReq, file);
                    addChapter(token, household.id, tonie.id, title, uploadReq.fileId);

                    writefln!"  ✓ '%s' uploaded."(title);
                }
                writeln("All files uploaded.");
                return 0;
            }
        );
    }
    catch (Exception e)
    {
        stderr.writefln!"Error: %s"(e.msg);
        return 1;
    }
});
