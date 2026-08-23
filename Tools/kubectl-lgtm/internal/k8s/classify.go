package k8s

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/omaksi/kubectl-lgtm/internal/config"
)

var zoneRe = regexp.MustCompile(`-zone-([a-z0-9]+)$`)

// Classifier maps workloads onto products and roles using configured rules
// rather than hardcoded ones, so an unusual deployment can be described in a
// config file instead of a patch.
type Classifier struct {
	productLabels []string
	roleLabels    []string
	// aliases maps a lowercase alias to its product, e.g. "cortex" → "mimir".
	aliases map[string]Product
	// roles is sorted longest-first so "query-frontend" is tested before
	// "querier". Sorting here means the configured order does not matter.
	roles     []string
	overrides []compiledOverride
}

type compiledOverride struct {
	namespace string
	name      *regexp.Regexp
	product   string
	role      string
	zone      string
}

// NewClassifier compiles the classification rules.
func NewClassifier(rules config.ClassifyRules) (*Classifier, error) {
	c := &Classifier{
		productLabels: rules.ProductLabels,
		roleLabels:    rules.RoleLabels,
		aliases:       make(map[string]Product),
		roles:         append([]string(nil), rules.Roles...),
	}

	for product, aliases := range rules.Products {
		c.aliases[strings.ToLower(product)] = Product(product)
		for _, a := range aliases {
			c.aliases[strings.ToLower(a)] = Product(product)
		}
	}

	// Longest role first, so a role that contains another as a prefix wins.
	sortByLengthDesc(c.roles)

	for i, o := range rules.Overrides {
		if o.Name == "" {
			return nil, fmt.Errorf("classify.overrides[%d]: name is required", i)
		}
		re, err := regexp.Compile(o.Name)
		if err != nil {
			return nil, fmt.Errorf("classify.overrides[%d]: bad name regex %q: %w", i, o.Name, err)
		}
		c.overrides = append(c.overrides, compiledOverride{
			namespace: o.Namespace,
			name:      re,
			product:   o.Product,
			role:      o.Role,
			zone:      o.Zone,
		})
	}
	return c, nil
}

func sortByLengthDesc(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && len(s[j]) > len(s[j-1]); j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// Classify derives the product, role and zone of a workload. Labels win over
// the name, and an override wins over both.
func (c *Classifier) Classify(namespace, name string, labels map[string]string) (Product, string, string) {
	lower := strings.ToLower(name)

	product := c.productFromLabels(labels)
	role := c.firstLabel(labels, c.roleLabels)

	if product == ProductUnknown {
		product = c.productFromName(lower)
	}
	if role == "" {
		role = roleFromSegments(lower, c.roles)
	}

	zone := ""
	if m := zoneRe.FindStringSubmatch(strings.ToLower(role)); m != nil {
		zone = m[1]
		role = strings.TrimSuffix(strings.ToLower(role), "-zone-"+zone)
	} else if m := zoneRe.FindStringSubmatch(lower); m != nil {
		zone = m[1]
	}

	for _, o := range c.overrides {
		if o.namespace != "" && o.namespace != namespace {
			continue
		}
		if !o.name.MatchString(name) {
			continue
		}
		if o.product != "" {
			product = Product(o.product)
		}
		if o.role != "" {
			role = o.role
		}
		if o.zone != "" {
			zone = o.zone
		}
		break
	}

	return product, role, zone
}

func (c *Classifier) firstLabel(labels map[string]string, keys []string) string {
	for _, k := range keys {
		if v := labels[k]; v != "" {
			return v
		}
	}
	return ""
}

func (c *Classifier) productFromLabels(labels map[string]string) Product {
	for _, k := range c.productLabels {
		if p, ok := c.aliases[strings.ToLower(labels[k])]; ok {
			return p
		}
	}
	return ProductUnknown
}

// productFromName matches aliases against whole dash-separated segments, so a
// release named "obs-mimir" classifies but an unrelated "mimirror" does not.
func (c *Classifier) productFromName(lower string) Product {
	segs := strings.Split(lower, "-")
	for alias, product := range c.aliases {
		if containsSegments(segs, strings.Split(alias, "-")) {
			return product
		}
	}
	return ProductUnknown
}

// roleFromSegments matches roles against whole dash-separated segments.
//
// Substring matching would be a trap here: short roles like "all" and "read"
// occur inside unrelated words, and a mis-detected role changes both the
// stateful/stateless advice and the values.yaml key in the snippet.
func roleFromSegments(lower string, roles []string) string {
	segs := strings.Split(lower, "-")
	for _, role := range roles {
		if containsSegments(segs, strings.Split(role, "-")) {
			return role
		}
	}
	return ""
}

func containsSegments(haystack, needle []string) bool {
	if len(needle) == 0 || len(needle) > len(haystack) {
		return false
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		match := true
		for j := range needle {
			if haystack[i+j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
