@if($page->hasPages())
    <div class="split pagination" aria-label="Pages">
        @if($page->previousPageUrl())<a href="{{ $page->previousPageUrl() }}">Previous</a>@endif
        @if($page->nextPageUrl())<a href="{{ $page->nextPageUrl() }}">Next</a>@endif
    </div>
@endif
