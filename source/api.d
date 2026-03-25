module api;

import std.json;
import std.string : format;
import std.stdio : writeln, stderr;
import requests;

private immutable string LOGIN_URL =
    "https://login.tonies.com/auth/realms/tonies/protocol/openid-connect/token";
private immutable string API_BASE = "https://api.tonie.cloud/v2";

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

struct Chapter
{
    string id;
    string title;
    string file;
    double seconds;
}

struct CreativeTonie
{
    string id;
    string householdId;
    string name;
    double secondsRemaining;
    double secondsPresent;
    int chaptersRemaining;
    int chaptersPresent;
    Chapter[] chapters;
}

struct Household
{
    string id;
    string name;
}

struct S3Fields
{
    string[string] fields;
    string url;
}

struct FileUploadRequest
{
    string fileId;
    S3Fields s3;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private JSONValue parseResponse(Response response, string context)
{
    if (response.code < 200 || response.code >= 300)
    {
        throw new Exception(format!"[%s] HTTP %d: %s"(context, response.code,
                cast(string) response.responseBody.data));
    }
    return parseJSON(cast(string) response.responseBody.data);
}

private Chapter parseChapter(JSONValue j)
{
    Chapter c;
    c.id = j["id"].str;
    c.title = j["title"].str;
    c.file = j["file"].str;
    c.seconds = j["seconds"].type == JSONType.integer
        ? cast(double) j["seconds"].integer
        : j["seconds"].floating;
    return c;
}

private CreativeTonie parseTonie(JSONValue j)
{
    CreativeTonie t;
    t.id = j["id"].str;
    t.householdId = j["householdId"].str;
    t.name = j["name"].str;
    t.secondsRemaining = j["secondsRemaining"].type == JSONType.integer
        ? cast(double) j["secondsRemaining"].integer
        : j["secondsRemaining"].floating;
    t.secondsPresent = j["secondsPresent"].type == JSONType.integer
        ? cast(double) j["secondsPresent"].integer
        : j["secondsPresent"].floating;
    t.chaptersRemaining = cast(int) j["chaptersRemaining"].integer;
    t.chaptersPresent = cast(int) j["chaptersPresent"].integer;
    foreach (ch; j["chapters"].array)
        t.chapters ~= parseChapter(ch);
    return t;
}

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

/// Authenticate with email/password and return a Bearer access token.
string authenticate(string email, string password)
{
    auto req = Request();
    req.addHeaders(["Content-Type": "application/x-www-form-urlencoded"]);

    string body_ = format!"grant_type=password&client_id=my-tonies&scope=openid&username=%s&password=%s"(
            email, password);

    auto resp = req.post(LOGIN_URL, body_, "application/x-www-form-urlencoded");

    if (resp.code != 200)
    {
        throw new Exception(
                format!"Authentication failed (HTTP %d): %s"(resp.code,
                cast(string) resp.responseBody.data));
    }

    auto json = parseJSON(cast(string) resp.responseBody.data);
    return json["access_token"].str;
}

// ---------------------------------------------------------------------------
// Households
// ---------------------------------------------------------------------------

/// Return all households for the authenticated user.
Household[] getHouseholds(string token)
{
    auto req = Request();
    req.addHeaders(["Authorization": "Bearer " ~ token]);

    auto resp = req.get(API_BASE ~ "/households");
    auto json = parseResponse(resp, "getHouseholds");

    Household[] result;
    foreach (h; json.array)
        result ~= Household(h["id"].str, h["name"].str);
    return result;
}

// ---------------------------------------------------------------------------
// Creative Tonies
// ---------------------------------------------------------------------------

/// Return all Creative Tonies in the given household.
CreativeTonie[] getCreativeTonies(string token, string householdId)
{
    auto req = Request();
    req.addHeaders(["Authorization": "Bearer " ~ token]);

    auto resp = req.get(API_BASE ~ "/households/" ~ householdId ~ "/creativetonies");
    auto json = parseResponse(resp, "getCreativeTonies");

    CreativeTonie[] result;
    foreach (t; json.array)
        result ~= parseTonie(t);
    return result;
}

// ---------------------------------------------------------------------------
// Clear chapters
// ---------------------------------------------------------------------------

/// Clear all chapters from a Creative Tonie by PATCHing with an empty chapters array.
void clearChapters(string token, string householdId, string tonieId)
{
    auto req = Request();
    req.addHeaders([
        "Authorization": "Bearer " ~ token,
        "Content-Type": "application/json"
    ]);

    string body_ = `{"chapters":[]}`;
    auto resp = req.patch(
            API_BASE ~ "/households/" ~ householdId ~ "/creativetonies/" ~ tonieId,
            body_, "application/json");
    parseResponse(resp, "clearChapters");
}

// ---------------------------------------------------------------------------
// File upload (3-step: request URL → upload to S3 → add chapter)
// ---------------------------------------------------------------------------

/// Step 1: Request a presigned S3 upload URL from the Tonie API.
FileUploadRequest requestUploadUrl(string token)
{
    auto req = Request();
    req.addHeaders(["Authorization": "Bearer " ~ token]);

    auto resp = req.post(API_BASE ~ "/file", "", "application/json");
    auto json = parseResponse(resp, "requestUploadUrl");

    FileUploadRequest fur;
    fur.fileId = json["fileId"].str;
    fur.s3.url = json["request"]["url"].str;
    foreach (key, val; json["request"]["fields"].object)
        fur.s3.fields[key] = val.str;
    return fur;
}

/// Step 2: Upload a local audio file to the presigned S3 URL.
/// onProgress is called with the byte count of each chunk as it is sent.
void uploadToS3(FileUploadRequest fur, string filePath, void delegate(size_t) onProgress = null)
{
    import std.stdio : File;
    import std.path : baseName;
    import requests.base : FormDataFile, FiniteReadable;

    class ProgressReadable : FiniteReadable
    {
        private FiniteReadable inner;
        this(FiniteReadable inner) { this.inner = inner; }

        override ulong getSize() { return inner.getSize(); }

        override ubyte[] read()
        {
            auto chunk = inner.read();
            if (chunk.length > 0 && onProgress !is null)
                onProgress(chunk.length);
            return chunk;
        }
    }

    auto req = Request();

    MultipartForm form;
    // Add all presigned S3 fields first
    foreach (key, val; fur.s3.fields)
        form.add(formData(key, val));

    // Stream the file in chunks without loading it fully into RAM
    auto readable = (onProgress !is null)
        ? cast(FiniteReadable) new ProgressReadable(new FormDataFile(File(filePath, "rb")))
        : new FormDataFile(File(filePath, "rb"));

    form.add("file", readable, [
        "filename": baseName(filePath),
        "Content-Type": "application/octet-stream"
    ]);

    auto resp = req.post(fur.s3.url, form);

    // S3 returns 204 No Content on success
    if (resp.code != 204 && resp.code != 200)
    {
        throw new Exception(
                format!"S3 upload failed (HTTP %d): %s"(resp.code,
                cast(string) resp.responseBody.data));
    }
}

/// A (title, fileId) pair describing a chapter to be set on a Creative Tonie.
struct NewChapter
{
    string title;
    string fileId;
}

/// Set the complete chapters list on a Creative Tonie in one PATCH request.
/// Replaces whatever was there before; pass an empty array to clear.
void setChapters(string token, string householdId, string tonieId, NewChapter[] chapters)
{
    auto req = Request();
    req.addHeaders([
        "Authorization": "Bearer " ~ token,
        "Content-Type": "application/json"
    ]);

    JSONValue[] chapterJson;
    foreach (ch; chapters)
        chapterJson ~= JSONValue(["title": JSONValue(ch.title), "file": JSONValue(ch.fileId)]);

    auto body_ = JSONValue(["chapters": JSONValue(chapterJson)]);
    auto resp = req.patch(
            API_BASE ~ "/households/" ~ householdId ~ "/creativetonies/" ~ tonieId,
            body_.toString(), "application/json");
    parseResponse(resp, "setChapters");
}
