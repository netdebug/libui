// 2 january 2017
#import "uipriv_darwin.h"
#import "draw.h"

// TODO what happens if nLines == 0 in any function?

struct uiDrawTextLayout {
	CFAttributedStringRef attrstr;

	// the width as passed into uiDrawTextLayout constructors
	double width;

	CTFramesetterRef framesetter;

	// the *actual* size of the frame
	// note: technically, metrics returned from frame are relative to CGPathGetPathBoundingBox(tl->path)
	// however, from what I can gather, for a path created by CGPathCreateWithRect(), like we do (with a NULL transform), CGPathGetPathBoundingBox() seems to just return the standardized form of the rect used to create the path
	// (this I confirmed through experimentation)
	// so we can just use tl->size for adjustments
	// we don't need to adjust coordinates by any origin since our rect origin is (0, 0)
	CGSize size;

	CGPathRef path;
	CTFrameRef frame;

	CFArrayRef lines;
	CFIndex nLines;
	// we compute this once when first creating the layout
	uiDrawTextLayoutLineMetrics *lineMetrics;

	// for converting CFAttributedString indices from/to byte offsets
	size_t *u8tou16;
	size_t nUTF8;
	size_t *u16tou8;
	size_t nUTF16;
};

static CTFontRef fontdescToCTFont(uiDrawFontDescriptor *fd)
{
	CTFontDescriptorRef desc;
	CTFontRef font;

	desc = fontdescToCTFontDescriptor(fd);
	font = CTFontCreateWithFontDescriptor(desc, fd->Size, NULL);
	CFRelease(desc);			// TODO correct?
	return font;
}

static CFAttributedStringRef attrstrToCoreFoundation(uiAttributedString *s, uiDrawFontDescriptor *defaultFont)
{
	CFStringRef cfstr;
	CFMutableDictionaryRef defaultAttrs;
	CTFontRef defaultCTFont;
	CFAttributedStringRef base;
	CFMutableAttributedStringRef mas;

	cfstr = CFStringCreateWithCharacters(NULL, attrstrUTF16(s), attrstrUTF16Len(s));
	if (cfstr == NULL) {
		// TODO
	}
	defaultAttrs = CFDictionaryCreateMutable(NULL, 1,
		&kCFCopyStringDictionaryKeyCallBacks,
		&kCFTypeDictionaryValueCallBacks);
	if (defaultAttrs == NULL) {
		// TODO
	}
	defaultCTFont = fontdescToCTFont(defaultFont);
	CFDictionaryAddValue(defaultAttrs, kCTFontAttributeName, defaultCTFont);
	CFRelease(defaultCTFont);

	base = CFAttributedStringCreate(NULL, cfstr, defaultAttrs);
	if (base == NULL) {
		// TODO
	}
	CFRelease(cfstr);
	CFRelease(defaultAttrs);
	mas = CFAttributedStringCreateMutableCopy(NULL, 0, base);
	CFRelease(base);

	CFAttributedStringBeginEditing(mas);
	// TODO copy in the attributes
	CFAttributedStringEndEditing(mas);

	return mas;
}

// TODO this is wrong for our hit-test example's multiple combining character example
static uiDrawTextLayoutLineMetrics *computeLineMetrics(CTFrameRef frame, CGSize size)
{
	uiDrawTextLayoutLineMetrics *metrics;
	CFArrayRef lines;
	CTLineRef line;
	CFIndex i, n;
	CGFloat ypos;
	CGRect bounds, boundsNoLeading;
	CGFloat ascent, descent, leading;
	CGPoint *origins;

	lines = CTFrameGetLines(frame);
	n = CFArrayGetCount(lines);
	metrics = (uiDrawTextLayoutLineMetrics *) uiAlloc(n * sizeof (uiDrawTextLayoutLineMetrics), "uiDrawTextLayoutLineMetrics[] (text layout)");

	origins = (CGPoint *) uiAlloc(n * sizeof (CGPoint), "CGPoint[] (text layout)");
	CTFrameGetLineOrigins(frame, CFRangeMake(0, n), origins);

	ypos = size.height;
	for (i = 0; i < n; i++) {
		line = (CTLineRef) CFArrayGetValueAtIndex(lines, i);
		bounds = CTLineGetBoundsWithOptions(line, 0);
		boundsNoLeading = CTLineGetBoundsWithOptions(line, kCTLineBoundsExcludeTypographicLeading);

		// this is equivalent to boundsNoLeading.size.height + boundsNoLeading.origin.y (manually verified)
		ascent = bounds.size.height + bounds.origin.y;
		descent = -boundsNoLeading.origin.y;
		// TODO does this preserve leading sign?
		leading = -bounds.origin.y - descent;

		// Core Text always rounds these up for paragraph style calculations; there is a flag to control it but it's inaccessible (and this behavior is turned off for old versions of iPhoto)
		ascent = floor(ascent + 0.5);
		descent = floor(descent + 0.5);
		if (leading > 0)
			leading = floor(leading + 0.5);

		metrics[i].X = origins[i].x;
		metrics[i].Y = origins[i].y - descent - leading;
		metrics[i].Width = bounds.size.width;
		metrics[i].Height = ascent + descent + leading;

		metrics[i].BaselineY = origins[i].y;
		metrics[i].Ascent = ascent;
		metrics[i].Descent = descent;
		metrics[i].Leading = leading;

		// TODO
		metrics[i].ParagraphSpacingBefore = 0;
		metrics[i].LineHeightSpace = 0;
		metrics[i].LineSpacing = 0;
		metrics[i].ParagraphSpacing = 0;

		// and finally advance to the next line
		ypos += metrics[i].Height;
	}

	// okay, but now all these metrics are unflipped
	// we need to flip them
	for (i = 0; i < n; i++) {
		metrics[i].Y = size.height - metrics[i].Y;
		// go from bottom-left corner to top-left
		metrics[i].Y -= metrics[i].Height;
		metrics[i].BaselineY = size.height - metrics[i].BaselineY;
		// TODO also adjust by metrics[i].Height?
	}

	uiFree(origins);
	return metrics;
}

uiDrawTextLayout *uiDrawNewTextLayout(uiAttributedString *s, uiDrawFontDescriptor *defaultFont, double width)
{
	uiDrawTextLayout *tl;
	CGFloat cgwidth;
	CFRange range, unused;
	CGRect rect;

	tl = uiNew(uiDrawTextLayout);
	tl->attrstr = attrstrToCoreFoundation(s, defaultFont);
	range.location = 0;
	range.length = CFAttributedStringGetLength(tl->attrstr);
	tl->width = width;

	// TODO CTFrameProgression for RTL/LTR
	// TODO kCTParagraphStyleSpecifierMaximumLineSpacing, kCTParagraphStyleSpecifierMinimumLineSpacing, kCTParagraphStyleSpecifierLineSpacingAdjustment for line spacing
	tl->framesetter = CTFramesetterCreateWithAttributedString(tl->attrstr);
	if (tl->framesetter == NULL) {
		// TODO
	}

	cgwidth = (CGFloat) width;
	if (cgwidth < 0)
		cgwidth = CGFLOAT_MAX;
	// TODO these seem to be floor()'d or truncated?
	// TODO double check to make sure this TODO was right
	tl->size = CTFramesetterSuggestFrameSizeWithConstraints(tl->framesetter,
		range,
		// TODO kCTFramePathWidthAttributeName?
		NULL,
		CGSizeMake(cgwidth, CGFLOAT_MAX),
		&unused);			// not documented as accepting NULL (TODO really?)

	rect.origin = CGPointZero;
	rect.size = tl->size;
	tl->path = CGPathCreateWithRect(rect, NULL);
	tl->frame = CTFramesetterCreateFrame(tl->framesetter,
		range,
		tl->path,
		// TODO kCTFramePathWidthAttributeName?
		NULL);
	if (tl->frame == NULL) {
		// TODO
	}

	tl->lines = CTFrameGetLines(tl->frame);
	tl->nLines = CFArrayGetCount(tl->lines);
	tl->lineMetrics = computeLineMetrics(tl->frame, tl->size);

	// and finally copy the UTF-8/UTF-16 conversion tables
	tl->u8tou16 = attrstrCopyUTF8ToUTF16(s, &(tl->nUTF8));
	tl->u16tou8 = attrstrCopyUTF16ToUTF8(s, &(tl->nUTF16));

	return tl;
}

void uiDrawFreeTextLayout(uiDrawTextLayout *tl)
{
	uiFree(tl->u16tou8);
	uiFree(tl->u8tou16);
	uiFree(tl->lineMetrics);
	// TODO release tl->lines?
	CFRelease(tl->frame);
	CFRelease(tl->path);
	CFRelease(tl->framesetter);
	CFRelease(tl->attrstr);
	uiFree(tl);
}

// TODO document that (x,y) is the top-left corner of the *entire frame*
void uiDrawText(uiDrawContext *c, uiDrawTextLayout *tl, double x, double y)
{
	CGContextSaveGState(c->c);

	// Core Text doesn't draw onto a flipped view correctly; we have to pretend it was unflipped
	// see the iOS bits of the first example at https://developer.apple.com/library/mac/documentation/StringsTextFonts/Conceptual/CoreText_Programming/LayoutOperations/LayoutOperations.html#//apple_ref/doc/uid/TP40005533-CH12-SW1 (iOS is naturally flipped)
	// TODO how is this affected by a non-identity CTM?
	CGContextTranslateCTM(c->c, 0, c->height);
	CGContextScaleCTM(c->c, 1.0, -1.0);
	CGContextSetTextMatrix(c->c, CGAffineTransformIdentity);

	// wait, that's not enough; we need to offset y values to account for our new flipping
	// TODO explain this calculation
	y = c->height - tl->size.height - y;

	// CTFrameDraw() draws in the path we specified when creating the frame
	// this means that in our usage, CTFrameDraw() will draw at (0,0)
	// so move the origin to be at (x,y) instead
	// TODO are the signs correct?
	CGContextTranslateCTM(c->c, x, y);

	CTFrameDraw(tl->frame, c->c);

	CGContextRestoreGState(c->c);
}

// TODO document that the width and height of a layout is not necessarily the sum of the widths and heights of its constituent lines; this is definitely untrue on OS X, where lines are placed in such a way that the distance between baselines is always integral
// TODO width doesn't include trailing whitespace...
// TODO figure out how paragraph spacing should play into this
void uiDrawTextLayoutExtents(uiDrawTextLayout *tl, double *width, double *height)
{
	*width = tl->size.width;
	*height = tl->size.height;
}

int uiDrawTextLayoutNumLines(uiDrawTextLayout *tl)
{
	return tl->nLines;
}

void uiDrawTextLayoutLineByteRange(uiDrawTextLayout *tl, int line, size_t *start, size_t *end)
{
	CTLineRef lr;
	CFRange range;

	lr = (CTLineRef) CFArrayGetValueAtIndex(tl->lines, line);
	range = CTLineGetStringRange(lr);
	*start = tl->u16tou8[range.location];
	*end = tl->u16tou8[range.location + range.length];
}

void uiDrawTextLayoutLineGetMetrics(uiDrawTextLayout *tl, int line, uiDrawTextLayoutLineMetrics *m)
{
	*m = tl->lineMetrics[line];
}

// TODO note that in some cases lines can overlap slightly
// in our case, we read lines first to last and use their bottommost point (Y + Height) to determine where the next line should start for hit-testing
void uiDrawTextLayoutHitTest(uiDrawTextLayout *tl, double x, double y, uiDrawTextLayoutHitTestResult *result)
{
	CFIndex i;
	CTLineRef line;
	CFIndex pos;

	if (y >= 0) {
		for (i = 0; i < tl->nLines; i++) {
			double ltop, lbottom;

			ltop = tl->lineMetrics[i].Y;
			lbottom = ltop + tl->lineMetrics[i].Height;
			// y will already >= ltop at this point since the past lbottom should == (or at least >=, see above) ltop
			if (y < lbottom)
				break;
		}
		result->YPosition = uiDrawTextLayoutHitTestPositionInside;
		if (i == tl->nLines) {
			i--;
			result->YPosition = uiDrawTextLayoutHitTestPositionAfter;
		}
	} else {
		i = 0;
		// TODO what if the first line crosses into the negatives?
		result->YPosition = uiDrawTextLayoutHitTestPositionBefore;
	}
	result->Line = i;

	result->XPosition = uiDrawTextLayoutHitTestPositionInside;
	if (x < tl->lineMetrics[i].X) {
		result->XPosition = uiDrawTextLayoutHitTestPositionBefore;
		// and forcibly return the first character
		x = tl->lineMetrics[i].X;
	} else if (x > (tl->lineMetrics[i].X + tl->lineMetrics[i].Width)) {
		result->XPosition = uiDrawTextLayoutHitTestPositionAfter;
		// and forcibly return the last character
		x = tl->lineMetrics[i].X + tl->lineMetrics[i].Width;
	}

	line = (CTLineRef) CFArrayGetValueAtIndex(tl->lines, i);
	// TODO copy the part from the docs about this point (TODO what point?)
	pos = CTLineGetStringIndexForPosition(line, CGPointMake(x, 0));
	if (pos == kCFNotFound) {
		// TODO
	}
	result->Pos = tl->u16tou8[pos];
}

// TODO document this is appropriate for a caret
// TODO what happens if we select across a wrapped line?
void uiDrawTextLayoutByteRangeToRectangle(uiDrawTextLayout *tl, size_t start, size_t end, uiDrawTextLayoutByteRangeRectangle *r)
{
	CFIndex i;
	CTLineRef line;
	CFRange range;
	CGFloat x, x2;		// TODO rename x to x1

	if (start > tl->nUTF8)
		start = tl->nUTF8;
	if (end > tl->nUTF8)
		end = tl->nUTF8;
	start = tl->u8tou16[start];
	end = tl->u8tou16[end];

	for (i = 0; i < tl->nLines; i++) {
		line = (CTLineRef) CFArrayGetValueAtIndex(tl->lines, i);
		range = CTLineGetStringRange(line);
		// TODO explain this check
		if (range.location >= start)
			break;
	}
	if (i == tl->nLines)
		i--;
	r->Line = i;
	if (end > (range.location + range.length))
		end = range.location + range.length;

	x = CTLineGetOffsetForStringIndex(line, start, NULL);
	x2 = CTLineGetOffsetForStringIndex(line, end, NULL);

	r->X = tl->lineMetrics[i].X + x;
	r->Y = tl->lineMetrics[i].Y;
	r->Width = (tl->lineMetrics[i].X + x2) - r->X;
	r->Height = tl->lineMetrics[i].Height;

	// and use x and x2 to get the actual start and end positions
	// TODO error check?
	r->RealStart = CTLineGetStringIndexForPosition(line, CGPointMake(x, 0));
	r->RealEnd = CTLineGetStringIndexForPosition(line, CGPointMake(x2, 0));
	r->RealStart = tl->u16tou8[r->RealStart];
	r->RealEnd = tl->u16tou8[r->RealEnd];
}
