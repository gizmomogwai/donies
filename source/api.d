module api;

import mir.deser.json : deserializeJson;
import mir.ser.json : serializeJson;
import mir.serde : serdeIgnoreUnexpectedKeys, serdeKeys;
import requests : formData, MultipartForm, Request, Response;
import requests.base : FiniteReadable, FormDataFile;
import std.path : baseName;
import std.stdio : File;
import std.string : format;
import std.uri : encodeComponent;

private immutable string LOGIN_URL = "https://login.tonies.com/auth/realms/tonies/protocol/openid-connect/token";
private immutable string API_BASE = "https://api.tonie.cloud/v2";

@serdeIgnoreUnexpectedKeys
struct Chapter
{
    string id;
    string title;
    string file;
    double seconds;
}

@serdeIgnoreUnexpectedKeys
struct CreativeTonie
{
    string id;
    string householdId;
    string name;
    double secondsRemaining;
    double secondsPresent;
    long chaptersRemaining;
    long chaptersPresent;
    Chapter[] chapters;
}

@serdeIgnoreUnexpectedKeys
struct Household
{
    string id;
    string name;
}

@serdeIgnoreUnexpectedKeys
struct S3Fields
{
    string[string] fields;
    string url;
}

@serdeIgnoreUnexpectedKeys
struct FileUploadRequest
{
    string fileId;
    @serdeKeys("request")
    S3Fields s3;
}

/// A (title, fileId) pair describing a chapter to be set on a Creative Tonie.
struct NewChapter
{
    string title;
    string fileId;
}

// ---------------------------------------------------------------------------
// Private types for serialisation / deserialisation
// ---------------------------------------------------------------------------

@serdeIgnoreUnexpectedKeys
private struct AuthResponse
{
    string access_token;
}

private struct ChapterEntry
{
    string title;
    string file;
}

private struct ChapterPatch
{
    ChapterEntry[] chapters;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private string checkResponse(Response response, string context)
{
    if (response.code < 200 || response.code >= 300)
    {
        throw new Exception(format!"[%s] HTTP %d: %s"(context, response.code,
                cast(string) response.responseBody.data));
    }
    return cast(string) response.responseBody.data;
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

string authenticate(string username, string password)
{
    auto req = Request();
    string body_ = format!"grant_type=password&client_id=my-tonies&scope=openid&username=%s&password=%s"(
            encodeComponent(username), encodeComponent(password));

    auto resp = req.post(LOGIN_URL, body_, "application/x-www-form-urlencoded");

    if (resp.code != 200)
        throw new Exception(format!"Authentication failed (HTTP %d): %s"(resp.code,
                cast(string) resp.responseBody.data));

    return (cast(string) resp.responseBody.data).deserializeJson!AuthResponse.access_token;
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
    return checkResponse(resp, "getHouseholds").deserializeJson!(Household[]);
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
    return checkResponse(resp, "getCreativeTonies").deserializeJson!(CreativeTonie[]);
}

void clearChapters(string token, string householdId, string tonieId)
{
    auto req = Request();
    req.addHeaders([
        "Authorization": "Bearer " ~ token,
        "Content-Type": "application/json"
    ]);

    auto resp = req.patch(API_BASE ~ "/households/" ~ householdId ~ "/creativetonies/" ~ tonieId,
            `{"chapters":[]}`, "application/json");
    checkResponse(resp, "clearChapters");
}

/// File upload (3-step: request URL → upload to S3 → set chapters)
FileUploadRequest requestUploadUrl(string token)
{
    auto req = Request();
    req.addHeaders(["Authorization": "Bearer " ~ token]);

    auto resp = req.post(API_BASE ~ "/file", "", "application/json");
    return checkResponse(resp, "requestUploadUrl").deserializeJson!FileUploadRequest;
}

/// Step 2: Upload a local audio file to the presigned S3 URL.
/// onProgress is called with the byte count of each chunk as it is sent.
void uploadToS3(FileUploadRequest fur, string filePath, void delegate(size_t) onProgress = null)
{

    class ProgressReadable : FiniteReadable
    {
        private FiniteReadable inner;
        this(FiniteReadable inner)
        {
            this.inner = inner;
        }

        override ulong getSize()
        {
            return inner.getSize();
        }

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
    auto readable = (onProgress !is null) ? cast(FiniteReadable) new ProgressReadable(
            new FormDataFile(File(filePath, "rb"))) : new FormDataFile(File(filePath, "rb"));

    form.add("file", readable, [
        "filename": baseName(filePath),
        "Content-Type": "application/octet-stream"
    ]);

    auto resp = req.post(fur.s3.url, form);

    // S3 returns 204 No Content on success
    if (resp.code != 204 && resp.code != 200)
    {
        throw new Exception(format!"S3 upload failed (HTTP %d): %s"(resp.code,
                cast(string) resp.responseBody.data));
    }
}

/// Set the complete chapters list on a Creative Tonie in one PATCH request.
/// Replaces whatever was there before; pass an empty array to clear.
void setChapters(string token, string householdId, string tonieId, NewChapter[] chapters)
{
    import std.algorithm : map;
    import std.array : array;

    auto req = Request();
    req.addHeaders([
        "Authorization": "Bearer " ~ token,
        "Content-Type": "application/json"
    ]);

    auto payload = ChapterPatch(
        chapters.map!(c => ChapterEntry(c.title, c.fileId)).array
    );

    auto resp = req.patch(API_BASE ~ "/households/" ~ householdId ~ "/creativetonies/" ~ tonieId,
            serializeJson(payload), "application/json");
    checkResponse(resp, "setChapters");
}

