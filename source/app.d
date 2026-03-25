module app;

import argparse;
import colored;
import std.conv : to;
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
// Output helpers
// ---------------------------------------------------------------------------

/// Bold cyan heading with a "==>" prefix.
private void heading(string msg)
{
    writeln(("==> " ~ msg).cyan.bold.to!string);
}

/// Indented detail line.
private void detail(string msg)
{
    writeln("    " ~ msg);
}

/// Green success line with a checkmark.
private void success(string msg)
{
    writeln(("    \u2713 " ~ msg).lightGreen.to!string);
}

/// Red error line with a cross.
private void fail(string msg)
{
    stderr.writeln(("    \u2717 " ~ msg).lightRed.bold.to!string);
}

// ---------------------------------------------------------------------------
// Lookup helpers
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
        heading(format!"Authenticating as %s ..."(prog.email));
        string token = authenticate(prog.email, prog.password);
        success("Authenticated.");

        return prog.cmd.matchCmd!(
            (List _)
            {
                heading("Fetching households ...");
                auto households = getHouseholds(token);
                foreach (h; households)
                {
                    writeln(("  Household: " ~ h.name).bold.to!string
                            ~ ("  (" ~ h.id ~ ")").darkGray.to!string);
                    auto tonies = getCreativeTonies(token, h.id);
                    foreach (t; tonies)
                    {
                        detail(format!"%s  id: %s  chapters: %d  %.0fs used"(
                            t.name.bold.to!string,
                            t.id.darkGray.to!string,
                            t.chaptersPresent,
                            t.secondsPresent));
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

                heading(format!"Clearing all chapters from '%s' ..."(tonie.name));
                clearChapters(token, household.id, tonie.id);
                success("All chapters cleared.");
                return 0;
            },
            (Upload cmd)
            {
                if (cmd.files.length == 0)
                {
                    fail("No files specified for upload.");
                    return 1;
                }

                auto households = getHouseholds(token);
                auto household  = resolveHousehold(households, cmd.household);
                auto tonies     = getCreativeTonies(token, household.id);
                auto tonie      = resolveTonie(tonies, cmd.tonie);

                heading(format!"Uploading %d file(s) in parallel ..."(cmd.files.length));

                import std.parallelism : parallel;
                auto results = new NewChapter[cmd.files.length];
                foreach (i, file; parallel(cmd.files))
                {
                    string title = stripExtension(baseName(file));
                    detail(format!"Uploading '%s' ..."(title));
                    auto uploadReq = requestUploadUrl(token);
                    uploadToS3(uploadReq, file);
                    results[i] = NewChapter(title, uploadReq.fileId);
                    success(format!"'%s' uploaded."(title));
                }

                heading(format!"Setting %d chapter(s) on '%s' ..."(results.length, tonie.name));
                setChapters(token, household.id, tonie.id, results);
                success(format!"%d chapter(s) committed to tonie."(results.length));
                return 0;
            }
        );
    }
    catch (Exception e)
    {
        fail(e.msg);
        return 1;
    }
});
