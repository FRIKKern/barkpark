# Patch: expose `DeleteJsonRecord` over HTTP in `IndxCloudApi`

**Status: PREPARED — NOT APPLIED. Do not run against production.**

The C# engine `IndxSearchLib 4.1.2` already implements
`bool DeleteJsonRecord(long id)` on the search engine, but the stock
`IndxCloudApi` `SearchController` does **not** expose it over HTTP. Barkpark's
`Barkpark.Plugins.Indx.Client.delete_json_record/3` calls
`DELETE /api/DeleteJsonRecord/{dataSetName}/{id}` — which 404s until this
additive action is added to the deployed controller.

This patch is the minimal additive action. It matches the existing
`SearchController` style exactly:

- class attribute `[Route("api")]`, so the action route is relative
  (`DeleteJsonRecord/{dataSetName}/{id:long}` → `/api/DeleteJsonRecord/...`);
- JWT bearer auth via
  `[Authorize(AuthenticationSchemes = JwtBearerDefaults.AuthenticationScheme)]`
  and the same `userId = User.FindFirst(ClaimTypes.NameIdentifier)?.Value`
  guard returning `Unauthorized()`;
- `[EnableCors("AllowAllHeaders")]` like every sibling action;
- resolves the live engine via
  `IndxCloudInternalApi.Manager.FindSearchEngine(dataSetName, userId)`
  (the same call `GetJson` uses) and `BadRequest`s a non-existing dataset;
- returns the `bool` result of `engine.DeleteJsonRecord(id)` **plus** the
  `SystemStatus` so the caller can read `ReIndexRequired` and decide whether a
  full rebuild fallback is needed (Barkpark's worker branches on exactly this).

## The action

Add this method inside `class SearchController` (e.g. right after the existing
`DeleteDataSet` action so the two delete verbs sit together):

```csharp
/// <summary>
/// DeleteJsonRecord removes a SINGLE indexed JSON record from a live dataset
/// by its numeric document key. Backs Barkpark's incremental per-document
/// delete (unpublish / delete) so the whole corpus does not have to be
/// rebuilt. Returns the engine's bool result together with the post-delete
/// SystemStatus, so the caller can inspect ReIndexRequired and fall back to a
/// full rebuild when the engine reports the change is not yet query-visible.
/// </summary>
/// <param name="dataSetName"></param>
/// <param name="id"></param>
/// <returns>DeleteJsonRecordResult { Deleted, Status }</returns>
[HttpDelete("DeleteJsonRecord/{dataSetName}/{id:long}")]
[Authorize(AuthenticationSchemes = JwtBearerDefaults.AuthenticationScheme)]
[EnableCors("AllowAllHeaders")]
public ActionResult<DeleteJsonRecordResult> DeleteJsonRecord(string dataSetName, long id)
{
    var userId = User.FindFirst(ClaimTypes.NameIdentifier)?.Value;
    if (string.IsNullOrEmpty(userId))
        return Unauthorized();
    if (!FileNameValidity.IsValid(dataSetName))
        return BadRequest("invalid dataSetName");

    var engine = IndxCloudInternalApi.Manager.FindSearchEngine(dataSetName, userId);
    if (engine == null)
        return BadRequest("DeleteJsonRecord non existing dataset name");
    if (engine.Status.SystemState == SystemState.Created || engine.Status.SystemState == SystemState.Loading)
        return BadRequest("DeleteJsonRecord invalid status, no data loaded or loading in progress");

    var deleted = engine.DeleteJsonRecord(id);
    var status = IndxCloudInternalApi.Manager.GetState(dataSetName, userId);

    return new DeleteJsonRecordResult
    {
        Deleted = deleted,
        Status = status
    };
}
```

And add this small response model (e.g. in `IndxCloudApi/Models`, alongside the
other proxy/result models the controller already references):

```csharp
namespace IndxCloudApi.Models
{
    public class DeleteJsonRecordResult
    {
        public bool Deleted { get; set; }
        public SystemStatus Status { get; set; }
    }
}
```

> If `SystemStatus` lives in a different namespace in your tree (it is the
> return type of the existing `GetStatus` action), reuse that exact type — do
> not introduce a second status type.

## Wire shape the Barkpark client expects

`Barkpark.Plugins.Indx.Client.delete_json_record/3` treats any 2xx as `:ok`
and reads the JSON body for `ReIndexRequired`. The serialized response is
camelCase (the controller's default), e.g.:

```json
{ "deleted": true, "status": { "reIndexRequired": false, "systemState": "Indexed", ... } }
```

`Barkpark.Plugins.Indx.Indexer.delete_record/3` reads `reIndexRequired` /
`ReIndexRequired` off the status body (it also checks a nested
`systemStatus`/`SystemStatus` wrapper). If your `SystemStatus` field is named
differently, adjust `reindex_required?/1` in `indexer.ex` to match the real
field name — confirm against a live `GetStatus` body first.

## Apply note

This is a prepared patch, **not applied**. To apply: in the cloned IndxCloudApi
source at `/opt/indx/src` (the `IndxCloudApi` project), paste the action into
`Controllers/SearchController.cs` and add the `DeleteJsonRecordResult` model,
then rebuild and restart the engine service:

```bash
cd /opt/indx/src
# add the action + model per above
dotnet publish IndxCloudApi -c Release --no-self-contained -o /opt/indx/publish
sudo systemctl restart indx.service
# smoke test (replace TOKEN/DS/ID):
curl -i -X DELETE -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:5001/api/DeleteJsonRecord/$DS/$ID
```

## UNPROVEN — must be spiked before prod

The 2026-06-01 spike only proved that **re-LOADing** an existing key onto a
live indexed dataset wedges the engine manager. It did **not** prove that a
targeted single-key `DeleteJsonRecord` on a live indexed dataset is safe —
whether it takes effect immediately, whether it flips `ReIndexRequired`, and
whether it leaves the engine queryable. **Spike `DeleteJsonRecord` against a
throwaway live dataset before relying on the incremental delete path in
production.** Until then the worker's reindex-required fallback (full rebuild)
is the safety net, and the delete op should be treated as best-effort.
